#pragma once
#include <QObject>
#include <QEvent>
#include <QTimer>
#include <QHash>
#include <QPair>
#include <QDateTime>
#include <QVariantMap>
#include <QFileSystemWatcher>
// On Windows SDL.h #defines main to SDL_main unless told the app owns its own
// entry point — without this the real main() vanishes and the link fails.
#define SDL_MAIN_HANDLED
#include <SDL.h>

class QQuickWindow;
class QKeyEvent;

// Centralized gamepad input. SDL controller buttons/axes are mapped to a small
// set of named actions (up/down/left/right/select/back/play_pause), and each
// action is delivered to QML as an ordinary synthesized key event posted to the
// root window — so every existing Keys.onPressed handler (including the Player
// views that forward keys to mpv over IPC) works without gamepad-specific code.
// Defaults can be overridden per-input in $DATA_ROOT/input.cfg (live-reloaded).
class InputManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool gamepadConnected READ gamepadConnected NOTIFY gamepadConnectedChanged)
    Q_PROPERTY(QString lastInputDevice READ lastInputDevice NOTIFY lastInputDeviceChanged)
    Q_PROPERTY(QVariantMap hints READ hints NOTIFY hintsChanged)

public:
    explicit InputManager(const QString &dataRoot, QObject *parent = nullptr);
    ~InputManager() override;

    void setTargetWindow(QQuickWindow *window);

    // App-level "controller_input" setting (default ON). While OFF, the app does
    // not open any controller at all, leaving the physical device entirely to
    // other apps (e.g. a user's Antimicro remapper driving the whole desktop);
    // pads are closed on the ON→OFF flip and (re)opened on OFF→ON, so toggling
    // works without a restart. Keyboard input is unaffected. Hotplug while OFF is
    // still noticed (so a later enable picks the pad up), just not opened.
    // Wired from main.cpp via appSettingChanged.
    void setControllerInputEnabled(bool on);

    // Touch/mouse → keyboard bridge for QML: posts a synthesized press+release
    // of the named action's key ("select", "back", "up", "down", "left",
    // "right", "play_pause") to the root window, so taps drive the exact same
    // Keys.on* handlers as the keyboard and remote. Unlike gamepad input this
    // does not flip lastInputDevice, so the footer hints stay keyboard-styled.
    Q_INVOKABLE void touchKey(const QString &action);

    bool gamepadConnected() const { return !m_controllers.isEmpty(); }
    QString lastInputDevice() const { return m_lastInputDevice; }
    QVariantMap hints() const { return m_hints; }

signals:
    void gamepadConnectedChanged();
    void lastInputDeviceChanged();
    void hintsChanged();
    // Emitted instead of posting a key event when the Qt window is inactive
    // (fullscreen mpv holds OS focus on macOS, which clears QML active focus).
    // main.cpp connects this to MpvController::sendKey.
    void mpvKeyRequested(const QString &key);

protected:
    bool eventFilter(QObject *obj, QEvent *event) override;

private slots:
    void pollSdl();
    void onRepeatDelayElapsed();
    void onRepeatTick();
    void onDataDirChanged(const QString &path);

private:
    enum class Action { None, Up, Down, Left, Right, Select, Back, PlayPause, PageUp, PageDown };

    void initSdl();
    void openController(int deviceIndex);
    void closeController(SDL_JoystickID instanceId);
    void openAllControllers();   // grab every connected pad (on enable)
    void closeAllControllers();  // release every open pad (on disable)
    void rebuildMapping();
    void loadDefaultMapping();
    void loadUserMapping();
    void noteActiveController(SDL_JoystickID which);
    void handleButton(SDL_JoystickID which, Uint8 button, bool pressed);
    void handleAxis(SDL_JoystickID which, Uint8 axis, Sint16 value);
    void pressAction(Action a);
    void releaseAction(Action a);
    void deliverPress(Action a, bool autoRepeat);
    void postKey(int qtKey, QEvent::Type type, bool autoRepeat);
    bool windowActive() const;
    void setLastInputDevice(const QString &device);
    void updateHints();
    QString labelForButton(int button) const;
    static int qtKeyForAction(Action a);
    static QString mpvKeyForAction(Action a);
    // Maps a HID media-key event to the canonical mpv key name media-keys.lua
    // binds, or an empty string for non-media keys.
    static QString mpvKeyForMediaEvent(const QKeyEvent *ke);
    static Action actionFromString(const QString &name, bool *ok);
    static int buttonFromToken(const QString &token);
    static bool isDirectional(Action a);

    QQuickWindow *m_window = nullptr;
    QString m_dataRoot;
    bool m_sdlReady = false;

    QTimer m_pollTimer;
    QTimer m_repeatDelayTimer;
    QTimer m_repeatTimer;
    QFileSystemWatcher m_watcher;
    QDateTime m_cfgLastModified;

    QHash<SDL_JoystickID, SDL_GameController*> m_controllers;
    QHash<int, Action> m_buttonMap;                  // SDL_GameControllerButton → Action
    QHash<int, QPair<Action, Action>> m_axisMap;     // SDL_GameControllerAxis → (negative, positive)
    QHash<int, int> m_axisState;                     // per-axis engaged direction: -1 / 0 / +1
    QHash<int, QString> m_labelOverrides;            // SDL button → user display label (input.cfg)
    SDL_JoystickID m_lastActiveController = -1;      // labels follow the pad last touched
    Action m_heldDirection = Action::None;

    QString m_lastInputDevice = "keyboard";
    QVariantMap m_hints;
    bool m_controllerInputEnabled = true;
};
