// Ghostty embedding API. The documentation for the embedding API is
// only within the Zig source files that define the implementations. This
// isn't meant to be a general purpose embedding API (yet) so there hasn't
// been documentation or example work beyond that.
//
// The only consumer of this API is the macOS app, but the API is built to
// be more general purpose.
#ifndef GHOSTTY_H
#define GHOSTTY_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _MSC_VER
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
#else
#include <sys/types.h>
#endif

//-------------------------------------------------------------------
// Macros

#define GHOSTTY_SUCCESS 0

// Symbol visibility for shared library builds. On Windows, functions
// are exported from the DLL when building and imported when consuming.
// On other platforms with GCC/Clang, functions are marked with default
// visibility so they remain accessible when the library is built with
// -fvisibility=hidden. For static library builds, define GHOSTTY_STATIC
// before including this header to make this a no-op.
#ifndef GHOSTTY_API
#if defined(GHOSTTY_STATIC)
  #define GHOSTTY_API
#elif defined(_WIN32) || defined(_WIN64)
  #ifdef GHOSTTY_BUILD_SHARED
    #define GHOSTTY_API __declspec(dllexport)
  #else
    #define GHOSTTY_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define GHOSTTY_API __attribute__((visibility("default")))
#else
  #define GHOSTTY_API
#endif
#endif

//-------------------------------------------------------------------
// Types

// Opaque types
typedef void* ghostty_app_t;
typedef void* ghostty_config_t;
typedef void* ghostty_surface_t;
typedef void* ghostty_inspector_t;

// Opaque handle to a remote-machine connection (see ghostty_remote_*). A
// connection is keyed by (host, user, port, jump-chain) and multiplexes N
// remote panes/sessions; it is owned by the Zig core and lives in the GUI
// process (a GUI crash disposes it; remote-side persistence is by session_id,
// see the remote-machines design doc §3.4/§3.5).
typedef void* ghostty_remote_connection_t;

// All the types below are fully defined and must be kept in sync with
// their Zig counterparts. Any changes to these types MUST have an associated
// Zig change.
typedef enum {
  GHOSTTY_PLATFORM_INVALID,
  GHOSTTY_PLATFORM_MACOS,
  GHOSTTY_PLATFORM_IOS,
} ghostty_platform_e;

typedef enum {
  GHOSTTY_CLIPBOARD_STANDARD,
  GHOSTTY_CLIPBOARD_SELECTION,
} ghostty_clipboard_e;

typedef struct {
  const char *mime;
  const char *data;
} ghostty_clipboard_content_s;

typedef enum {
  GHOSTTY_CLIPBOARD_REQUEST_PASTE,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
} ghostty_clipboard_request_e;

typedef enum {
  GHOSTTY_MOUSE_RELEASE,
  GHOSTTY_MOUSE_PRESS,
} ghostty_input_mouse_state_e;

typedef enum {
  GHOSTTY_MOUSE_UNKNOWN,
  GHOSTTY_MOUSE_LEFT,
  GHOSTTY_MOUSE_RIGHT,
  GHOSTTY_MOUSE_MIDDLE,
  GHOSTTY_MOUSE_FOUR,
  GHOSTTY_MOUSE_FIVE,
  GHOSTTY_MOUSE_SIX,
  GHOSTTY_MOUSE_SEVEN,
  GHOSTTY_MOUSE_EIGHT,
  GHOSTTY_MOUSE_NINE,
  GHOSTTY_MOUSE_TEN,
  GHOSTTY_MOUSE_ELEVEN,
} ghostty_input_mouse_button_e;

typedef enum {
  GHOSTTY_MOUSE_MOMENTUM_NONE,
  GHOSTTY_MOUSE_MOMENTUM_BEGAN,
  GHOSTTY_MOUSE_MOMENTUM_STATIONARY,
  GHOSTTY_MOUSE_MOMENTUM_CHANGED,
  GHOSTTY_MOUSE_MOMENTUM_ENDED,
  GHOSTTY_MOUSE_MOMENTUM_CANCELLED,
  GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN,
} ghostty_input_mouse_momentum_e;

typedef enum {
  GHOSTTY_COLOR_SCHEME_LIGHT = 0,
  GHOSTTY_COLOR_SCHEME_DARK = 1,
} ghostty_color_scheme_e;

// This is a packed struct (see src/input/mouse.zig) but the C standard
// afaik doesn't let us reliably define packed structs so we build it up
// from scratch.
typedef int ghostty_input_scroll_mods_t;

typedef enum {
  GHOSTTY_MODS_NONE = 0,
  GHOSTTY_MODS_SHIFT = 1 << 0,
  GHOSTTY_MODS_CTRL = 1 << 1,
  GHOSTTY_MODS_ALT = 1 << 2,
  GHOSTTY_MODS_SUPER = 1 << 3,
  GHOSTTY_MODS_CAPS = 1 << 4,
  GHOSTTY_MODS_NUM = 1 << 5,
  GHOSTTY_MODS_SHIFT_RIGHT = 1 << 6,
  GHOSTTY_MODS_CTRL_RIGHT = 1 << 7,
  GHOSTTY_MODS_ALT_RIGHT = 1 << 8,
  GHOSTTY_MODS_SUPER_RIGHT = 1 << 9,
} ghostty_input_mods_e;

typedef enum {
  GHOSTTY_BINDING_FLAGS_CONSUMED = 1 << 0,
  GHOSTTY_BINDING_FLAGS_ALL = 1 << 1,
  GHOSTTY_BINDING_FLAGS_GLOBAL = 1 << 2,
  GHOSTTY_BINDING_FLAGS_PERFORMABLE = 1 << 3,
} ghostty_binding_flags_e;

typedef enum {
  GHOSTTY_ACTION_RELEASE,
  GHOSTTY_ACTION_PRESS,
  GHOSTTY_ACTION_REPEAT,
} ghostty_input_action_e;

// Based on: https://www.w3.org/TR/uievents-code/
typedef enum {
  GHOSTTY_KEY_UNIDENTIFIED,

  // "Writing System Keys" § 3.1.1
  GHOSTTY_KEY_BACKQUOTE,
  GHOSTTY_KEY_BACKSLASH,
  GHOSTTY_KEY_BRACKET_LEFT,
  GHOSTTY_KEY_BRACKET_RIGHT,
  GHOSTTY_KEY_COMMA,
  GHOSTTY_KEY_DIGIT_0,
  GHOSTTY_KEY_DIGIT_1,
  GHOSTTY_KEY_DIGIT_2,
  GHOSTTY_KEY_DIGIT_3,
  GHOSTTY_KEY_DIGIT_4,
  GHOSTTY_KEY_DIGIT_5,
  GHOSTTY_KEY_DIGIT_6,
  GHOSTTY_KEY_DIGIT_7,
  GHOSTTY_KEY_DIGIT_8,
  GHOSTTY_KEY_DIGIT_9,
  GHOSTTY_KEY_EQUAL,
  GHOSTTY_KEY_INTL_BACKSLASH,
  GHOSTTY_KEY_INTL_RO,
  GHOSTTY_KEY_INTL_YEN,
  GHOSTTY_KEY_A,
  GHOSTTY_KEY_B,
  GHOSTTY_KEY_C,
  GHOSTTY_KEY_D,
  GHOSTTY_KEY_E,
  GHOSTTY_KEY_F,
  GHOSTTY_KEY_G,
  GHOSTTY_KEY_H,
  GHOSTTY_KEY_I,
  GHOSTTY_KEY_J,
  GHOSTTY_KEY_K,
  GHOSTTY_KEY_L,
  GHOSTTY_KEY_M,
  GHOSTTY_KEY_N,
  GHOSTTY_KEY_O,
  GHOSTTY_KEY_P,
  GHOSTTY_KEY_Q,
  GHOSTTY_KEY_R,
  GHOSTTY_KEY_S,
  GHOSTTY_KEY_T,
  GHOSTTY_KEY_U,
  GHOSTTY_KEY_V,
  GHOSTTY_KEY_W,
  GHOSTTY_KEY_X,
  GHOSTTY_KEY_Y,
  GHOSTTY_KEY_Z,
  GHOSTTY_KEY_MINUS,
  GHOSTTY_KEY_PERIOD,
  GHOSTTY_KEY_QUOTE,
  GHOSTTY_KEY_SEMICOLON,
  GHOSTTY_KEY_SLASH,

  // "Functional Keys" § 3.1.2
  GHOSTTY_KEY_ALT_LEFT,
  GHOSTTY_KEY_ALT_RIGHT,
  GHOSTTY_KEY_BACKSPACE,
  GHOSTTY_KEY_CAPS_LOCK,
  GHOSTTY_KEY_CONTEXT_MENU,
  GHOSTTY_KEY_CONTROL_LEFT,
  GHOSTTY_KEY_CONTROL_RIGHT,
  GHOSTTY_KEY_ENTER,
  GHOSTTY_KEY_META_LEFT,
  GHOSTTY_KEY_META_RIGHT,
  GHOSTTY_KEY_SHIFT_LEFT,
  GHOSTTY_KEY_SHIFT_RIGHT,
  GHOSTTY_KEY_SPACE,
  GHOSTTY_KEY_TAB,
  GHOSTTY_KEY_CONVERT,
  GHOSTTY_KEY_KANA_MODE,
  GHOSTTY_KEY_NON_CONVERT,

  // "Control Pad Section" § 3.2
  GHOSTTY_KEY_DELETE,
  GHOSTTY_KEY_END,
  GHOSTTY_KEY_HELP,
  GHOSTTY_KEY_HOME,
  GHOSTTY_KEY_INSERT,
  GHOSTTY_KEY_PAGE_DOWN,
  GHOSTTY_KEY_PAGE_UP,

  // "Arrow Pad Section" § 3.3
  GHOSTTY_KEY_ARROW_DOWN,
  GHOSTTY_KEY_ARROW_LEFT,
  GHOSTTY_KEY_ARROW_RIGHT,
  GHOSTTY_KEY_ARROW_UP,

  // "Numpad Section" § 3.4
  GHOSTTY_KEY_NUM_LOCK,
  GHOSTTY_KEY_NUMPAD_0,
  GHOSTTY_KEY_NUMPAD_1,
  GHOSTTY_KEY_NUMPAD_2,
  GHOSTTY_KEY_NUMPAD_3,
  GHOSTTY_KEY_NUMPAD_4,
  GHOSTTY_KEY_NUMPAD_5,
  GHOSTTY_KEY_NUMPAD_6,
  GHOSTTY_KEY_NUMPAD_7,
  GHOSTTY_KEY_NUMPAD_8,
  GHOSTTY_KEY_NUMPAD_9,
  GHOSTTY_KEY_NUMPAD_ADD,
  GHOSTTY_KEY_NUMPAD_BACKSPACE,
  GHOSTTY_KEY_NUMPAD_CLEAR,
  GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY,
  GHOSTTY_KEY_NUMPAD_COMMA,
  GHOSTTY_KEY_NUMPAD_DECIMAL,
  GHOSTTY_KEY_NUMPAD_DIVIDE,
  GHOSTTY_KEY_NUMPAD_ENTER,
  GHOSTTY_KEY_NUMPAD_EQUAL,
  GHOSTTY_KEY_NUMPAD_MEMORY_ADD,
  GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR,
  GHOSTTY_KEY_NUMPAD_MEMORY_RECALL,
  GHOSTTY_KEY_NUMPAD_MEMORY_STORE,
  GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT,
  GHOSTTY_KEY_NUMPAD_MULTIPLY,
  GHOSTTY_KEY_NUMPAD_PAREN_LEFT,
  GHOSTTY_KEY_NUMPAD_PAREN_RIGHT,
  GHOSTTY_KEY_NUMPAD_SUBTRACT,
  GHOSTTY_KEY_NUMPAD_SEPARATOR,
  GHOSTTY_KEY_NUMPAD_UP,
  GHOSTTY_KEY_NUMPAD_DOWN,
  GHOSTTY_KEY_NUMPAD_RIGHT,
  GHOSTTY_KEY_NUMPAD_LEFT,
  GHOSTTY_KEY_NUMPAD_BEGIN,
  GHOSTTY_KEY_NUMPAD_HOME,
  GHOSTTY_KEY_NUMPAD_END,
  GHOSTTY_KEY_NUMPAD_INSERT,
  GHOSTTY_KEY_NUMPAD_DELETE,
  GHOSTTY_KEY_NUMPAD_PAGE_UP,
  GHOSTTY_KEY_NUMPAD_PAGE_DOWN,

  // "Function Section" § 3.5
  GHOSTTY_KEY_ESCAPE,
  GHOSTTY_KEY_F1,
  GHOSTTY_KEY_F2,
  GHOSTTY_KEY_F3,
  GHOSTTY_KEY_F4,
  GHOSTTY_KEY_F5,
  GHOSTTY_KEY_F6,
  GHOSTTY_KEY_F7,
  GHOSTTY_KEY_F8,
  GHOSTTY_KEY_F9,
  GHOSTTY_KEY_F10,
  GHOSTTY_KEY_F11,
  GHOSTTY_KEY_F12,
  GHOSTTY_KEY_F13,
  GHOSTTY_KEY_F14,
  GHOSTTY_KEY_F15,
  GHOSTTY_KEY_F16,
  GHOSTTY_KEY_F17,
  GHOSTTY_KEY_F18,
  GHOSTTY_KEY_F19,
  GHOSTTY_KEY_F20,
  GHOSTTY_KEY_F21,
  GHOSTTY_KEY_F22,
  GHOSTTY_KEY_F23,
  GHOSTTY_KEY_F24,
  GHOSTTY_KEY_F25,
  GHOSTTY_KEY_FN,
  GHOSTTY_KEY_FN_LOCK,
  GHOSTTY_KEY_PRINT_SCREEN,
  GHOSTTY_KEY_SCROLL_LOCK,
  GHOSTTY_KEY_PAUSE,

  // "Media Keys" § 3.6
  GHOSTTY_KEY_BROWSER_BACK,
  GHOSTTY_KEY_BROWSER_FAVORITES,
  GHOSTTY_KEY_BROWSER_FORWARD,
  GHOSTTY_KEY_BROWSER_HOME,
  GHOSTTY_KEY_BROWSER_REFRESH,
  GHOSTTY_KEY_BROWSER_SEARCH,
  GHOSTTY_KEY_BROWSER_STOP,
  GHOSTTY_KEY_EJECT,
  GHOSTTY_KEY_LAUNCH_APP_1,
  GHOSTTY_KEY_LAUNCH_APP_2,
  GHOSTTY_KEY_LAUNCH_MAIL,
  GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
  GHOSTTY_KEY_MEDIA_SELECT,
  GHOSTTY_KEY_MEDIA_STOP,
  GHOSTTY_KEY_MEDIA_TRACK_NEXT,
  GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
  GHOSTTY_KEY_POWER,
  GHOSTTY_KEY_SLEEP,
  GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
  GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
  GHOSTTY_KEY_AUDIO_VOLUME_UP,
  GHOSTTY_KEY_WAKE_UP,

  // "Legacy, Non-standard, and Special Keys" § 3.7
  GHOSTTY_KEY_COPY,
  GHOSTTY_KEY_CUT,
  GHOSTTY_KEY_PASTE,
} ghostty_input_key_e;

typedef struct {
  ghostty_input_action_e action;
  ghostty_input_mods_e mods;
  ghostty_input_mods_e consumed_mods;
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} ghostty_input_key_s;

typedef enum {
  GHOSTTY_TRIGGER_PHYSICAL,
  GHOSTTY_TRIGGER_UNICODE,
  GHOSTTY_TRIGGER_CATCH_ALL,
} ghostty_input_trigger_tag_e;

typedef union {
  ghostty_input_key_e physical;
  uint32_t unicode;
  // catch_all has no payload
} ghostty_input_trigger_key_u;

typedef struct {
  ghostty_input_trigger_tag_e tag;
  ghostty_input_trigger_key_u key;
  ghostty_input_mods_e mods;
} ghostty_input_trigger_s;

typedef struct {
  const char* action_key;
  const char* action;
  const char* title;
  const char* description;
} ghostty_command_s;

typedef enum {
  GHOSTTY_BUILD_MODE_DEBUG,
  GHOSTTY_BUILD_MODE_RELEASE_SAFE,
  GHOSTTY_BUILD_MODE_RELEASE_FAST,
  GHOSTTY_BUILD_MODE_RELEASE_SMALL,
} ghostty_build_mode_e;

typedef struct {
  ghostty_build_mode_e build_mode;
  const char* version;
  uintptr_t version_len;
} ghostty_info_s;

typedef struct {
  const char* message;
} ghostty_diagnostic_s;

typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} ghostty_string_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} ghostty_text_s;

typedef enum {
  GHOSTTY_POINT_ACTIVE,
  GHOSTTY_POINT_VIEWPORT,
  GHOSTTY_POINT_SCREEN,
  GHOSTTY_POINT_SURFACE,
} ghostty_point_tag_e;

typedef enum {
  GHOSTTY_POINT_COORD_EXACT,
  GHOSTTY_POINT_COORD_TOP_LEFT,
  GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
} ghostty_point_coord_e;

typedef struct {
  ghostty_point_tag_e tag;
  ghostty_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} ghostty_point_s;

typedef struct {
  ghostty_point_s top_left;
  ghostty_point_s bottom_right;
  bool rectangle;
} ghostty_selection_s;

typedef struct {
  const char* key;
  const char* value;
} ghostty_env_var_s;

typedef struct {
  void* nsview;
} ghostty_platform_macos_s;

typedef struct {
  void* uiview;
} ghostty_platform_ios_s;

typedef union {
  ghostty_platform_macos_s macos;
  ghostty_platform_ios_s ios;
} ghostty_platform_u;

typedef enum {
  GHOSTTY_SURFACE_CONTEXT_WINDOW = 0,
  GHOSTTY_SURFACE_CONTEXT_TAB = 1,
  GHOSTTY_SURFACE_CONTEXT_SPLIT = 2,
} ghostty_surface_context_e;

typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  ghostty_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;

  // Remote-machine backend (remote-machines design §3.2). When `connection`
  // is non-NULL, the surface is constructed with the `.remote` termio backend
  // riding on that connection instead of the local exec/pty backend. The
  // connection must already be started and handshake-complete (see
  // ghostty_remote_connection_start / _wait_handshake). It is caller-owned and
  // may be shared across surfaces; it is NOT freed when the surface is freed.
  //
  // `session_id` is the agent session to ATTACH to (re-attach to an existing
  // remote session); NULL means OPEN a brand-new session. Ignored when
  // `connection` is NULL.
  ghostty_remote_connection_t connection;
  const char* session_id;

  // Explicit REMOTE working directory for an OPEN-new remote session (§WP4).
  // This is the cwd ON THE REMOTE MACHINE the new pane should start in — set by
  // the split/tab path from an on-demand cwd query of the parent remote pane.
  // It is forwarded verbatim to the agent's OPEN. It is DISTINCT from
  // `working_directory` above (a LOCAL path that must never reach a remote
  // agent). NULL means "no remote cwd hint" — the agent uses its own default.
  // Ignored when `connection` is NULL.
  const char* remote_working_directory;
} ghostty_surface_config_s;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} ghostty_surface_size_s;

// Config types

// config.Path
typedef struct {
  const char* path;
  bool optional;
} ghostty_config_path_s;

// config.Color
typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} ghostty_config_color_s;

// config.ColorList
typedef struct {
  const ghostty_config_color_s* colors;
  size_t len;
} ghostty_config_color_list_s;

// config.RepeatableCommand
typedef struct {
  const ghostty_command_s* commands;
  size_t len;
} ghostty_config_command_list_s;

// config.Palette
typedef struct {
  ghostty_config_color_s colors[256];
} ghostty_config_palette_s;

// config.QuickTerminalSize
typedef enum {
  GHOSTTY_QUICK_TERMINAL_SIZE_NONE,
  GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE,
  GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS,
} ghostty_quick_terminal_size_tag_e;

typedef union {
  float percentage;
  uint32_t pixels;
} ghostty_quick_terminal_size_value_u;

typedef struct {
  ghostty_quick_terminal_size_tag_e tag;
  ghostty_quick_terminal_size_value_u value;
} ghostty_quick_terminal_size_s;

typedef struct {
  ghostty_quick_terminal_size_s primary;
  ghostty_quick_terminal_size_s secondary;
} ghostty_config_quick_terminal_size_s;

// config.Fullscreen
typedef enum {
  GHOSTTY_CONFIG_FULLSCREEN_FALSE,
  GHOSTTY_CONFIG_FULLSCREEN_TRUE,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE_VISIBLE_MENU,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE_PADDED_NOTCH,
} ghostty_config_fullscreen_e;

// apprt.Target.Key
typedef enum {
  GHOSTTY_TARGET_APP,
  GHOSTTY_TARGET_SURFACE,
} ghostty_target_tag_e;

typedef union {
  ghostty_surface_t surface;
} ghostty_target_u;

typedef struct {
  ghostty_target_tag_e tag;
  ghostty_target_u target;
} ghostty_target_s;

// apprt.action.SplitDirection
typedef enum {
  GHOSTTY_SPLIT_DIRECTION_RIGHT,
  GHOSTTY_SPLIT_DIRECTION_DOWN,
  GHOSTTY_SPLIT_DIRECTION_LEFT,
  GHOSTTY_SPLIT_DIRECTION_UP,
} ghostty_action_split_direction_e;

// apprt.action.GotoSplit
typedef enum {
  GHOSTTY_GOTO_SPLIT_PREVIOUS,
  GHOSTTY_GOTO_SPLIT_NEXT,
  GHOSTTY_GOTO_SPLIT_UP,
  GHOSTTY_GOTO_SPLIT_LEFT,
  GHOSTTY_GOTO_SPLIT_DOWN,
  GHOSTTY_GOTO_SPLIT_RIGHT,
} ghostty_action_goto_split_e;

// apprt.action.GotoWindow
typedef enum {
  GHOSTTY_GOTO_WINDOW_PREVIOUS,
  GHOSTTY_GOTO_WINDOW_NEXT,
} ghostty_action_goto_window_e;

// apprt.action.ResizeSplit.Direction
typedef enum {
  GHOSTTY_RESIZE_SPLIT_UP,
  GHOSTTY_RESIZE_SPLIT_DOWN,
  GHOSTTY_RESIZE_SPLIT_LEFT,
  GHOSTTY_RESIZE_SPLIT_RIGHT,
} ghostty_action_resize_split_direction_e;

// apprt.action.ResizeSplit
typedef struct {
  uint16_t amount;
  ghostty_action_resize_split_direction_e direction;
} ghostty_action_resize_split_s;

// apprt.action.MoveTab
typedef struct {
  ssize_t amount;
} ghostty_action_move_tab_s;

// apprt.action.GotoTab
typedef enum {
  GHOSTTY_GOTO_TAB_PREVIOUS = -1,
  GHOSTTY_GOTO_TAB_NEXT = -2,
  GHOSTTY_GOTO_TAB_LAST = -3,
} ghostty_action_goto_tab_e;

// apprt.action.Fullscreen
typedef enum {
  GHOSTTY_FULLSCREEN_NATIVE,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH,
} ghostty_action_fullscreen_e;

// apprt.action.FloatWindow
typedef enum {
  GHOSTTY_FLOAT_WINDOW_ON,
  GHOSTTY_FLOAT_WINDOW_OFF,
  GHOSTTY_FLOAT_WINDOW_TOGGLE,
} ghostty_action_float_window_e;

// apprt.action.SecureInput
typedef enum {
  GHOSTTY_SECURE_INPUT_ON,
  GHOSTTY_SECURE_INPUT_OFF,
  GHOSTTY_SECURE_INPUT_TOGGLE,
} ghostty_action_secure_input_e;

// apprt.action.Inspector
typedef enum {
  GHOSTTY_INSPECTOR_TOGGLE,
  GHOSTTY_INSPECTOR_SHOW,
  GHOSTTY_INSPECTOR_HIDE,
} ghostty_action_inspector_e;

// apprt.action.QuitTimer
typedef enum {
  GHOSTTY_QUIT_TIMER_START,
  GHOSTTY_QUIT_TIMER_STOP,
} ghostty_action_quit_timer_e;

// apprt.action.Readonly
typedef enum {
  GHOSTTY_READONLY_OFF,
  GHOSTTY_READONLY_ON,
} ghostty_action_readonly_e;

// apprt.action.DesktopNotification.C
typedef struct {
  const char* title;
  const char* body;
} ghostty_action_desktop_notification_s;

// apprt.action.SetTitle.C
typedef struct {
  const char* title;
} ghostty_action_set_title_s;

// apprt.action.PromptTitle
typedef enum {
  GHOSTTY_PROMPT_TITLE_SURFACE,
  GHOSTTY_PROMPT_TITLE_TAB,
} ghostty_action_prompt_title_e;

// apprt.action.Pwd.C
typedef struct {
  const char* pwd;
} ghostty_action_pwd_s;

// terminal.MouseShape
typedef enum {
  GHOSTTY_MOUSE_SHAPE_DEFAULT,
  GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU,
  GHOSTTY_MOUSE_SHAPE_HELP,
  GHOSTTY_MOUSE_SHAPE_POINTER,
  GHOSTTY_MOUSE_SHAPE_PROGRESS,
  GHOSTTY_MOUSE_SHAPE_WAIT,
  GHOSTTY_MOUSE_SHAPE_CELL,
  GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
  GHOSTTY_MOUSE_SHAPE_TEXT,
  GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT,
  GHOSTTY_MOUSE_SHAPE_ALIAS,
  GHOSTTY_MOUSE_SHAPE_COPY,
  GHOSTTY_MOUSE_SHAPE_MOVE,
  GHOSTTY_MOUSE_SHAPE_NO_DROP,
  GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
  GHOSTTY_MOUSE_SHAPE_GRAB,
  GHOSTTY_MOUSE_SHAPE_GRABBING,
  GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
  GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_N_RESIZE,
  GHOSTTY_MOUSE_SHAPE_E_RESIZE,
  GHOSTTY_MOUSE_SHAPE_S_RESIZE,
  GHOSTTY_MOUSE_SHAPE_W_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
  GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
} ghostty_action_mouse_shape_e;

// apprt.action.MouseVisibility
typedef enum {
  GHOSTTY_MOUSE_VISIBLE,
  GHOSTTY_MOUSE_HIDDEN,
} ghostty_action_mouse_visibility_e;

// apprt.action.MouseOverLink
typedef struct {
  const char* url;
  size_t len;
} ghostty_action_mouse_over_link_s;

// apprt.action.SizeLimit
typedef struct {
  uint32_t min_width;
  uint32_t min_height;
  uint32_t max_width;
  uint32_t max_height;
} ghostty_action_size_limit_s;

// apprt.action.InitialSize
typedef struct {
  uint32_t width;
  uint32_t height;
} ghostty_action_initial_size_s;

// apprt.action.CellSize
typedef struct {
  uint32_t width;
  uint32_t height;
} ghostty_action_cell_size_s;

// renderer.Health
typedef enum {
  GHOSTTY_RENDERER_HEALTH_HEALTHY,
  GHOSTTY_RENDERER_HEALTH_UNHEALTHY,
} ghostty_action_renderer_health_e;

// apprt.action.KeySequence
typedef struct {
  bool active;
  ghostty_input_trigger_s trigger;
} ghostty_action_key_sequence_s;

// apprt.action.KeyTable.Tag
typedef enum {
  GHOSTTY_KEY_TABLE_ACTIVATE,
  GHOSTTY_KEY_TABLE_DEACTIVATE,
  GHOSTTY_KEY_TABLE_DEACTIVATE_ALL,
} ghostty_action_key_table_tag_e;

// apprt.action.KeyTable.CValue
typedef union {
  struct {
    const char *name;
    size_t len;
  } activate;
} ghostty_action_key_table_u;

// apprt.action.KeyTable.C
typedef struct {
  ghostty_action_key_table_tag_e tag;
  ghostty_action_key_table_u value;
} ghostty_action_key_table_s;

// apprt.action.ColorKind
typedef enum {
  GHOSTTY_ACTION_COLOR_KIND_FOREGROUND = -1,
  GHOSTTY_ACTION_COLOR_KIND_BACKGROUND = -2,
  GHOSTTY_ACTION_COLOR_KIND_CURSOR = -3,
} ghostty_action_color_kind_e;

// apprt.action.ColorChange
typedef struct {
  ghostty_action_color_kind_e kind;
  uint8_t r;
  uint8_t g;
  uint8_t b;
} ghostty_action_color_change_s;

// apprt.action.ConfigChange
typedef struct {
  ghostty_config_t config;
} ghostty_action_config_change_s;

// apprt.action.ReloadConfig
typedef struct {
  bool soft;
} ghostty_action_reload_config_s;

// apprt.action.OpenUrlKind
typedef enum {
  GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
  GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
  GHOSTTY_ACTION_OPEN_URL_KIND_HTML,
} ghostty_action_open_url_kind_e;

// apprt.action.OpenUrl.C
typedef struct {
  ghostty_action_open_url_kind_e kind;
  const char* url;
  uintptr_t len;
} ghostty_action_open_url_s;

// apprt.action.CloseTabMode
typedef enum {
  GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS,
  GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER,
  GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT,
} ghostty_action_close_tab_mode_e;

// apprt.surface.Message.ChildExited
typedef struct {
  uint32_t exit_code;
  uint64_t timetime_ms;
} ghostty_surface_message_childexited_s;

// terminal.osc.Command.ProgressReport.State
typedef enum {
  GHOSTTY_PROGRESS_STATE_REMOVE,
  GHOSTTY_PROGRESS_STATE_SET,
  GHOSTTY_PROGRESS_STATE_ERROR,
  GHOSTTY_PROGRESS_STATE_INDETERMINATE,
  GHOSTTY_PROGRESS_STATE_PAUSE,
} ghostty_action_progress_report_state_e;

// terminal.osc.Command.ProgressReport.C
typedef struct {
  ghostty_action_progress_report_state_e state;
  // -1 if no progress was reported, otherwise 0-100 indicating percent
  // completeness.
  int8_t progress;
} ghostty_action_progress_report_s;

// apprt.action.CommandFinished.C
typedef struct {
  // -1 if no exit code was reported, otherwise 0-255
  int16_t exit_code;
  // number of nanoseconds that command was running for
  uint64_t duration;
} ghostty_action_command_finished_s;

// apprt.action.StartSearch.C
typedef struct {
  const char* needle;
} ghostty_action_start_search_s;

// apprt.action.SearchTotal
typedef struct {
  ssize_t total;
} ghostty_action_search_total_s;

// apprt.action.SearchSelected
typedef struct {
  ssize_t selected;
} ghostty_action_search_selected_s;

// terminal.Scrollbar
typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t len;
} ghostty_action_scrollbar_s;

// terminal.osc.Command.ActivityState
typedef enum {
  GHOSTTY_ACTIVITY_STATE_IDLE,
  GHOSTTY_ACTIVITY_STATE_BUSY,
  GHOSTTY_ACTIVITY_STATE_NEEDS_INPUT,
} ghostty_activity_state_e;

// apprt.Action.Key
typedef enum {
  GHOSTTY_ACTION_QUIT,
  GHOSTTY_ACTION_NEW_WINDOW,
  GHOSTTY_ACTION_NEW_TAB,
  GHOSTTY_ACTION_CLOSE_TAB,
  GHOSTTY_ACTION_NEW_SPLIT,
  GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
  GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
  GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
  GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
  GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
  GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
  GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
  GHOSTTY_ACTION_TOGGLE_VISIBILITY,
  GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
  GHOSTTY_ACTION_MOVE_TAB,
  GHOSTTY_ACTION_GOTO_TAB,
  GHOSTTY_ACTION_GOTO_SPLIT,
  GHOSTTY_ACTION_SWAP_SPLIT,
  GHOSTTY_ACTION_GOTO_WINDOW,
  GHOSTTY_ACTION_RESIZE_SPLIT,
  GHOSTTY_ACTION_EQUALIZE_SPLITS,
  GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
  GHOSTTY_ACTION_TOGGLE_HERO_MODE,
  GHOSTTY_ACTION_PRESENT_TERMINAL,
  GHOSTTY_ACTION_SIZE_LIMIT,
  GHOSTTY_ACTION_RESET_WINDOW_SIZE,
  GHOSTTY_ACTION_INITIAL_SIZE,
  GHOSTTY_ACTION_CELL_SIZE,
  GHOSTTY_ACTION_SCROLLBAR,
  GHOSTTY_ACTION_RENDER,
  GHOSTTY_ACTION_INSPECTOR,
  GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
  GHOSTTY_ACTION_RENDER_INSPECTOR,
  GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
  GHOSTTY_ACTION_SET_TITLE,
  GHOSTTY_ACTION_SET_TAB_TITLE,
  GHOSTTY_ACTION_PROMPT_TITLE,
  GHOSTTY_ACTION_PWD,
  GHOSTTY_ACTION_MOUSE_SHAPE,
  GHOSTTY_ACTION_MOUSE_VISIBILITY,
  GHOSTTY_ACTION_MOUSE_OVER_LINK,
  GHOSTTY_ACTION_RENDERER_HEALTH,
  GHOSTTY_ACTION_OPEN_CONFIG,
  GHOSTTY_ACTION_QUIT_TIMER,
  GHOSTTY_ACTION_FLOAT_WINDOW,
  GHOSTTY_ACTION_SECURE_INPUT,
  GHOSTTY_ACTION_KEY_SEQUENCE,
  GHOSTTY_ACTION_KEY_TABLE,
  GHOSTTY_ACTION_COLOR_CHANGE,
  GHOSTTY_ACTION_RELOAD_CONFIG,
  GHOSTTY_ACTION_CONFIG_CHANGE,
  GHOSTTY_ACTION_CLOSE_WINDOW,
  GHOSTTY_ACTION_RING_BELL,
  GHOSTTY_ACTION_UNDO,
  GHOSTTY_ACTION_REDO,
  GHOSTTY_ACTION_CHECK_FOR_UPDATES,
  GHOSTTY_ACTION_OPEN_URL,
  GHOSTTY_ACTION_SHOW_CHILD_EXITED,
  GHOSTTY_ACTION_PROGRESS_REPORT,
  GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
  GHOSTTY_ACTION_COMMAND_FINISHED,
  GHOSTTY_ACTION_START_SEARCH,
  GHOSTTY_ACTION_END_SEARCH,
  GHOSTTY_ACTION_SEARCH_TOTAL,
  GHOSTTY_ACTION_SEARCH_SELECTED,
  GHOSTTY_ACTION_READONLY,
  GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD,
  GHOSTTY_ACTION_ACTIVITY_STATE,
} ghostty_action_tag_e;

typedef union {
  ghostty_action_split_direction_e new_split;
  ghostty_action_fullscreen_e toggle_fullscreen;
  ghostty_action_move_tab_s move_tab;
  ghostty_action_goto_tab_e goto_tab;
  ghostty_action_goto_split_e goto_split;
  ghostty_action_goto_split_e swap_split;
  ghostty_action_goto_window_e goto_window;
  ghostty_action_resize_split_s resize_split;
  ghostty_action_size_limit_s size_limit;
  ghostty_action_initial_size_s initial_size;
  ghostty_action_cell_size_s cell_size;
  ghostty_action_scrollbar_s scrollbar;
  ghostty_action_inspector_e inspector;
  ghostty_action_desktop_notification_s desktop_notification;
  ghostty_action_set_title_s set_title;
  ghostty_action_set_title_s set_tab_title;
  ghostty_action_prompt_title_e prompt_title;
  ghostty_action_pwd_s pwd;
  ghostty_action_mouse_shape_e mouse_shape;
  ghostty_action_mouse_visibility_e mouse_visibility;
  ghostty_action_mouse_over_link_s mouse_over_link;
  ghostty_action_renderer_health_e renderer_health;
  ghostty_action_quit_timer_e quit_timer;
  ghostty_action_float_window_e float_window;
  ghostty_action_secure_input_e secure_input;
  ghostty_action_key_sequence_s key_sequence;
  ghostty_action_key_table_s key_table;
  ghostty_action_color_change_s color_change;
  ghostty_action_reload_config_s reload_config;
  ghostty_action_config_change_s config_change;
  ghostty_action_open_url_s open_url;
  ghostty_action_close_tab_mode_e close_tab_mode;
  ghostty_surface_message_childexited_s child_exited;
  ghostty_action_progress_report_s progress_report;
  ghostty_action_command_finished_s command_finished;
  ghostty_action_start_search_s start_search;
  ghostty_action_search_total_s search_total;
  ghostty_action_search_selected_s search_selected;
  ghostty_action_readonly_e readonly;
  ghostty_activity_state_e activity_state;
} ghostty_action_u;

typedef struct {
  ghostty_action_tag_e tag;
  ghostty_action_u action;
} ghostty_action_s;

typedef void (*ghostty_runtime_wakeup_cb)(void*);
typedef bool (*ghostty_runtime_read_clipboard_cb)(void*,
                                                  ghostty_clipboard_e,
                                                  void*);
typedef void (*ghostty_runtime_confirm_read_clipboard_cb)(
    void*,
    const char*,
    void*,
    ghostty_clipboard_request_e);
typedef void (*ghostty_runtime_write_clipboard_cb)(void*,
                                                   ghostty_clipboard_e,
                                                   const ghostty_clipboard_content_s*,
                                                   size_t,
                                                   bool);
typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t,
                                          ghostty_target_s,
                                          ghostty_action_s);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  ghostty_runtime_wakeup_cb wakeup_cb;
  ghostty_runtime_action_cb action_cb;
  ghostty_runtime_read_clipboard_cb read_clipboard_cb;
  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  ghostty_runtime_write_clipboard_cb write_clipboard_cb;
  ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;

// apprt.ipc.Target.Key
typedef enum {
  GHOSTTY_IPC_TARGET_CLASS,
  GHOSTTY_IPC_TARGET_DETECT,
} ghostty_ipc_target_tag_e;

typedef union {
  char *klass;
} ghostty_ipc_target_u;

typedef struct {
  ghostty_ipc_target_tag_e tag;
  ghostty_ipc_target_u target;
} chostty_ipc_target_s;

// apprt.ipc.Action.NewWindow
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_new_window_s;

// apprt.ipc.Action.Split
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_split_s;

// apprt.ipc.Action.Close
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_close_s;

// apprt.ipc.Action.Rename
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_rename_s;

// apprt.ipc.Action.Rearrange
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_rearrange_s;

// apprt.ipc.Action.SendKeys
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_send_keys_s;

// apprt.ipc.Action.SetState
typedef struct {
  const char **arguments;
} ghostty_ipc_action_set_state_s;

typedef union {
  ghostty_ipc_action_new_window_s new_window;
  ghostty_ipc_action_split_s split;
  ghostty_ipc_action_close_s close;
  ghostty_ipc_action_rename_s rename;
  ghostty_ipc_action_rearrange_s rearrange;
  ghostty_ipc_action_send_keys_s send_keys;
  ghostty_ipc_action_set_state_s set_state;
} ghostty_ipc_action_u;

// apprt.ipc.Action.Key
typedef enum {
  GHOSTTY_IPC_ACTION_NEW_WINDOW,
  GHOSTTY_IPC_ACTION_SPLIT,
  GHOSTTY_IPC_ACTION_CLOSE,
  GHOSTTY_IPC_ACTION_RENAME,
  GHOSTTY_IPC_ACTION_REARRANGE,
  GHOSTTY_IPC_ACTION_SEND_KEYS,
  GHOSTTY_IPC_ACTION_SET_STATE,
} ghostty_ipc_action_tag_e;

//-------------------------------------------------------------------
// Published API

GHOSTTY_API int ghostty_init(uintptr_t, char**);
GHOSTTY_API void ghostty_cli_try_action(void);
GHOSTTY_API const char* ghostty_pending_ipc_json(void);
GHOSTTY_API void ghostty_consume_pending_ipc_json(void);
GHOSTTY_API ghostty_info_s ghostty_info(void);
GHOSTTY_API const char* ghostty_translate(const char*);
GHOSTTY_API void ghostty_string_free(ghostty_string_s);

GHOSTTY_API ghostty_config_t ghostty_config_new();
GHOSTTY_API void ghostty_config_free(ghostty_config_t);
GHOSTTY_API ghostty_config_t ghostty_config_clone(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_cli_args(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_file(ghostty_config_t, const char*);
GHOSTTY_API void ghostty_config_load_default_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_recursive_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_finalize(ghostty_config_t);
GHOSTTY_API bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t);
GHOSTTY_API ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t,
                                                              const char*,
                                                              uintptr_t);
GHOSTTY_API bool ghostty_config_key_is_binding(ghostty_config_t, ghostty_input_key_s);
GHOSTTY_API uint32_t ghostty_config_diagnostics_count(ghostty_config_t);
GHOSTTY_API ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t, uint32_t);
GHOSTTY_API ghostty_string_s ghostty_config_open_path(void);

GHOSTTY_API ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*,
                                             ghostty_config_t);
GHOSTTY_API void ghostty_app_free(ghostty_app_t);
GHOSTTY_API void ghostty_app_tick(ghostty_app_t);
GHOSTTY_API void* ghostty_app_userdata(ghostty_app_t);
GHOSTTY_API void ghostty_app_set_focus(ghostty_app_t, bool);
GHOSTTY_API bool ghostty_app_key(ghostty_app_t, ghostty_input_key_s);
GHOSTTY_API void ghostty_app_keyboard_changed(ghostty_app_t);
GHOSTTY_API void ghostty_app_open_config(ghostty_app_t);
GHOSTTY_API void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);
GHOSTTY_API bool ghostty_app_needs_confirm_quit(ghostty_app_t);
GHOSTTY_API bool ghostty_app_has_global_keybinds(ghostty_app_t);
GHOSTTY_API void ghostty_app_set_color_scheme(ghostty_app_t, ghostty_color_scheme_e);

GHOSTTY_API ghostty_surface_config_s ghostty_surface_config_new();

GHOSTTY_API ghostty_surface_t ghostty_surface_new(ghostty_app_t,
                                                     const ghostty_surface_config_s*);
GHOSTTY_API void ghostty_surface_free(ghostty_surface_t);
GHOSTTY_API void* ghostty_surface_userdata(ghostty_surface_t);
GHOSTTY_API ghostty_app_t ghostty_surface_app(ghostty_surface_t);
GHOSTTY_API ghostty_surface_config_s ghostty_surface_inherited_config(ghostty_surface_t, ghostty_surface_context_e);
GHOSTTY_API void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);
GHOSTTY_API bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_process_exited(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_refresh(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_draw(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_set_content_scale(ghostty_surface_t, double, double);
GHOSTTY_API void ghostty_surface_set_focus(ghostty_surface_t, bool);
GHOSTTY_API void ghostty_surface_set_occlusion(ghostty_surface_t, bool);
GHOSTTY_API void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);
GHOSTTY_API ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);
GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);
GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_set_color_scheme(ghostty_surface_t,
                                                     ghostty_color_scheme_e);
GHOSTTY_API void ghostty_surface_set_color(ghostty_surface_t,
                                              int kind, uint8_t index,
                                              uint8_t r, uint8_t g, uint8_t b);
GHOSTTY_API void ghostty_surface_reset_colors(ghostty_surface_t);
GHOSTTY_API ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                                         ghostty_input_mods_e);
GHOSTTY_API bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
GHOSTTY_API bool ghostty_surface_key_is_binding(ghostty_surface_t,
                                                   ghostty_input_key_s,
                                                   ghostty_binding_flags_e*);
GHOSTTY_API void ghostty_surface_write_pty(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API bool ghostty_surface_mouse_captured(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_mouse_button(ghostty_surface_t,
                                                 ghostty_input_mouse_state_e,
                                                 ghostty_input_mouse_button_e,
                                                 ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_pos(ghostty_surface_t,
                                              double,
                                              double,
                                              ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_scroll(ghostty_surface_t,
                                                 double,
                                                 double,
                                                 ghostty_input_scroll_mods_t);
GHOSTTY_API void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);
GHOSTTY_API void ghostty_surface_ime_point(ghostty_surface_t, double*, double*, double*, double*);
GHOSTTY_API void ghostty_surface_request_close(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_split(ghostty_surface_t, ghostty_action_split_direction_e);
GHOSTTY_API void ghostty_surface_split_focus(ghostty_surface_t,
                                                ghostty_action_goto_split_e);
GHOSTTY_API void ghostty_surface_split_swap(ghostty_surface_t,
                                               ghostty_action_goto_split_e);
GHOSTTY_API void ghostty_surface_split_resize(ghostty_surface_t,
                                                 ghostty_action_resize_split_direction_e,
                                                 uint16_t);
GHOSTTY_API void ghostty_surface_split_equalize(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_binding_action(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_complete_clipboard_request(ghostty_surface_t,
                                                               const char*,
                                                               void*,
                                                               bool);
GHOSTTY_API bool ghostty_surface_has_selection(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);
GHOSTTY_API bool ghostty_surface_read_text(ghostty_surface_t,
                                              ghostty_selection_s,
                                              ghostty_text_s*);
GHOSTTY_API void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);

// Remote machines (remote-machines design §3.5/§3.2). A connection is keyed by
// (host, user, port, jump-chain) and multiplexes N remote panes/sessions. The
// returned handle is owned by the caller and must be released with
// ghostty_remote_connection_free.
//
// NOTE (WP3): the live SSH dial is not implemented yet. `_new` records the
// dial parameters and constructs the connection object but does NOT yet spawn
// `ssh`; `_start` therefore currently returns false ("not yet implemented").
// The ABI shape is stable so the Swift app can bind against it now.
typedef struct {
  const char* host;        // Required: remote host (alias or address).
  const char* user;        // Optional (NULL): SSH user; NULL uses ssh defaults.
  uint16_t port;           // SSH port; 0 means the ssh default (22).
  const char* jump;        // Optional (NULL): comma-separated ProxyJump chain.
} ghostty_remote_config_s;

// Create a remote connection handle from dial parameters. Returns NULL on
// allocation failure or invalid parameters (e.g. NULL host). The handle is not
// connected yet — call ghostty_remote_connection_start.
GHOSTTY_API ghostty_remote_connection_t ghostty_remote_connection_new(
    const ghostty_remote_config_s*);

// Create a remote connection by dialing a TCP-listening ghoztty-agent directly
// at host:port (WP4). This connects the socket and BLOCKS through the HELLO
// handshake before returning, so the handle is fully established — a subsequent
// ghostty_remote_connection_start is a no-op (returns true) and
// _wait_handshake returns true immediately. Returns NULL on a NULL/empty host
// or any dial/handshake failure. The transport encoding is raw (a clean
// TCP/Tailscale hop). Free with ghostty_remote_connection_free.
GHOSTTY_API ghostty_remote_connection_t ghostty_remote_connection_new_tcp(
    const char* host, uint16_t port);

// Start the connection: dial SSH, spawn the reader/writer threads, and send
// the client HELLO. Returns true on success. WP3: currently returns false
// (live SSH dial not yet wired).
GHOSTTY_API bool ghostty_remote_connection_start(ghostty_remote_connection_t);

// Block until the protocol handshake completes (or fails). Returns true if the
// handshake negotiated successfully. Safe to call only after _start succeeded.
GHOSTTY_API bool ghostty_remote_connection_wait_handshake(
    ghostty_remote_connection_t);

// Current smoothed latency in milliseconds, or -1 if not yet measured.
GHOSTTY_API int32_t ghostty_remote_connection_latency_ms(
    ghostty_remote_connection_t);

// Shut down and free the connection. Detaches all panes (sessions survive on
// the remote for later re-attach by session_id). Caller must ensure no surface
// still references this connection.
GHOSTTY_API void ghostty_remote_connection_free(ghostty_remote_connection_t);

// On-demand query for a remote session's child working directory. Blocks
// (bounded timeout) for the agent's reply. On success the returned string holds
// the UTF-8 path; on failure (no connection, unknown session, agent query
// failed, or timeout) it is empty (ptr == NULL). Free with ghostty_string_free.
// Used at split/tab time so a new remote pane inherits the parent's cwd.
GHOSTTY_API ghostty_string_s ghostty_remote_connection_query_cwd(
    ghostty_remote_connection_t, const char* session_id);

// Like ghostty_remote_connection_query_cwd but with an explicit timeout in
// milliseconds (0 => default 10s). Run on a background thread with a tight bound
// so a new remote frame's cwd inheritance never blocks the main thread.
GHOSTTY_API ghostty_string_s ghostty_remote_connection_query_cwd_timeout(
    ghostty_remote_connection_t, const char* session_id, uint32_t timeout_ms);

// A host-metrics snapshot pushed by the remote agent (activity monitor). Mirrors
// the wire HostMetrics. uptime_s is 0 when the remote OS doesn't expose uptime;
// load1 is -1 when there is no load average (e.g. Windows).
typedef struct {
  float cpu_pct;     // busy CPU % 0..100 across all cores since the prev sample
  uint64_t mem_used; // used physical memory, bytes
  uint64_t mem_total; // total physical memory, bytes
  uint32_t ncpu;     // logical CPU count
  uint64_t uptime_s; // seconds since boot, 0 if unknown
  float load1;       // 1-minute load average, -1 if unknown
} ghostty_host_metrics_s;

// Callback for each pushed host-metrics sample. IMPORTANT: it fires on the
// connection's control-reader thread, NOT the main thread — hop to the main
// queue before touching UI. The metrics pointer borrows stack storage valid only
// for the duration of the call; copy the fields out. The void* is the userdata
// passed to ghostty_remote_connection_metrics_subscribe.
typedef void (*ghostty_metrics_callback)(const ghostty_host_metrics_s*, void*);

// Subscribe to the remote host's pushed metrics stream. The agent pushes a
// sample every interval_ms; each is delivered to the callback. Returns false if
// the connection isn't established. The caller MUST call _metrics_unsubscribe (or
// _free) before freeing anything userdata points at. A second subscribe replaces
// the callback.
GHOSTTY_API bool ghostty_remote_connection_metrics_subscribe(
    ghostty_remote_connection_t, uint32_t interval_ms,
    ghostty_metrics_callback, void* userdata);

// Stop the pushed metrics stream and clear the callback. After this returns no
// further metrics callback fires. Safe to call when not subscribed (no-op).
GHOSTTY_API void ghostty_remote_connection_metrics_unsubscribe(
    ghostty_remote_connection_t);

// One row of the remote host's process table (activity monitor process view).
// name/user/cmd are ALWAYS non-NULL NUL-terminated UTF-8 C strings — an empty
// string ("") means "unavailable", never a NULL pointer. cpu_pct is PER-CORE: a
// fully-busy single thread is ~100; a multithreaded process can exceed 100.
// Divide by host.ncpu for a Task-Manager-style 0..100 total.
typedef struct {
  int64_t pid;
  int64_t ppid;
  float cpu_pct;      // per-core busy % (may exceed 100 for multithreaded procs)
  uint64_t mem_bytes; // resident/working-set bytes
  const char* name;   // process name (never NULL; "" if unknown)
  const char* user;   // owning user (never NULL; "" if unavailable)
  const char* cmd;    // command line (never NULL; "" if unavailable)
} ghostty_proc_s;

// A one-shot snapshot of the remote host's process table. ok == false means the
// call failed (no connection, agent error, or timeout) and procs_len == 0. The
// host field mirrors ghostty_host_metrics_s (cpu_pct may be 0 here — a one-shot
// host read has no baseline; subscribe to the metrics stream for an accurate host
// CPU%). Free with ghostty_remote_connection_proc_list_free.
typedef struct {
  bool ok;
  bool truncated;            // the agent clipped the table to its default cap
  ghostty_host_metrics_s host;
  ghostty_proc_s* procs;     // procs_len rows (valid pointer even when len == 0)
  size_t procs_len;
} ghostty_proc_list_s;

// Fetch the remote host's process table. SYNCHRONOUS: this blocks on the RPC reply
// up to timeout_ms (0 => default 10s), so run it OFF the main thread. Returns a
// snapshot with ok == false (and procs_len == 0) on failure. Free the result with
// ghostty_remote_connection_proc_list_free.
GHOSTTY_API ghostty_proc_list_s ghostty_remote_connection_proc_list(
    ghostty_remote_connection_t, uint32_t timeout_ms);

// Free a process-table snapshot returned by ghostty_remote_connection_proc_list.
// Takes the same connection handle (its allocator owns the rows/strings). Always
// safe (a failed/empty snapshot frees nothing).
GHOSTTY_API void ghostty_remote_connection_proc_list_free(
    ghostty_remote_connection_t, ghostty_proc_list_s);

// The live remote agent session id for a surface, or an empty string (ptr ==
// NULL) for a local surface or one whose remote pane is not yet resolved. Free
// with ghostty_string_free.
GHOSTTY_API ghostty_string_s ghostty_surface_remote_session_id(ghostty_surface_t);

// The command a surface's remote pane was OPENed with, or an empty string (ptr
// == NULL) for a local surface or one whose remote pane uses the agent's default
// shell. Free with ghostty_string_free. Used so a new window/tab/split inherits
// the parent remote frame's command.
GHOSTTY_API ghostty_string_s ghostty_surface_remote_command(ghostty_surface_t);

#ifdef __APPLE__
GHOSTTY_API void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);
GHOSTTY_API void* ghostty_surface_quicklook_font(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_quicklook_word(ghostty_surface_t, ghostty_text_s*);
#endif

GHOSTTY_API ghostty_inspector_t ghostty_surface_inspector(ghostty_surface_t);
GHOSTTY_API void ghostty_inspector_free(ghostty_surface_t);
GHOSTTY_API void ghostty_inspector_set_focus(ghostty_inspector_t, bool);
GHOSTTY_API void ghostty_inspector_set_content_scale(ghostty_inspector_t, double, double);
GHOSTTY_API void ghostty_inspector_set_size(ghostty_inspector_t, uint32_t, uint32_t);
GHOSTTY_API void ghostty_inspector_mouse_button(ghostty_inspector_t,
                                                   ghostty_input_mouse_state_e,
                                                   ghostty_input_mouse_button_e,
                                                   ghostty_input_mods_e);
GHOSTTY_API void ghostty_inspector_mouse_pos(ghostty_inspector_t, double, double);
GHOSTTY_API void ghostty_inspector_mouse_scroll(ghostty_inspector_t,
                                                   double,
                                                   double,
                                                   ghostty_input_scroll_mods_t);
GHOSTTY_API void ghostty_inspector_key(ghostty_inspector_t,
                                          ghostty_input_action_e,
                                          ghostty_input_key_e,
                                          ghostty_input_mods_e);
GHOSTTY_API void ghostty_inspector_text(ghostty_inspector_t, const char*);

#ifdef __APPLE__
GHOSTTY_API bool ghostty_inspector_metal_init(ghostty_inspector_t, void*);
GHOSTTY_API void ghostty_inspector_metal_render(ghostty_inspector_t, void*, void*);
GHOSTTY_API bool ghostty_inspector_metal_shutdown(ghostty_inspector_t);
#endif

// APIs I'd like to get rid of eventually but are still needed for now.
// Don't use these unless you know what you're doing.
GHOSTTY_API void ghostty_set_window_background_blur(ghostty_app_t, void*);

// Benchmark API, if available.
GHOSTTY_API bool ghostty_benchmark_cli(const char*, const char*);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_H */
