#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>

#define WM_IME_SETCONTEXT 0x0281
#define WM_IME_NOTIFY 0x0282
#define WM_IME_ENDCOMPOSITION 0x010E
#define IMN_CLOSESTATUSWINDOW 0x0001

#define MAX_TARGET_WINDOWS 32
#define MAX_WINDOW_TITLE_LEN 256
#define MAX_CLASS_NAME_LEN 128

#define DEFAULT_INTERVAL_MS 2000
#define MINIMUM_INTERVAL_MS 100
#define SEND_TIMEOUT_MS 1000
#define HOTKEY_POLL_MS 50

#define UNUSED(var) (void)var

enum ProgramModeEnum {
	PROGRAM_MODE_ONCE,
	PROGRAM_MODE_HOTKEY,
	PROGRAM_MODE_PERIODIC,
	PROGRAM_MODE_SPECIFIC
};

typedef struct {
	UINT message_id;
	WPARAM wparam;
	LPARAM lparam;
	const char *description;
} ImeMessage;

static ImeMessage imemsg_end_composition_only[] = {
    {WM_IME_ENDCOMPOSITION, 0, 0, "WM_IME_ENDCOMPOSITION"},
};

static ImeMessage imemsg_all_ime_messages[] = {
    {WM_IME_ENDCOMPOSITION, 0, 0, "WM_IME_ENDCOMPOSITION"},
    {WM_IME_SETCONTEXT, 0, 0, "WM_IME_SETCONTEXT(deactivate)"},
    {WM_IME_SETCONTEXT, 1, 0, "WM_IME_SETCONTEXT(activate)"},
    {WM_IME_NOTIFY, IMN_CLOSESTATUSWINDOW, 0, "WM_IME_NOTIFY(CLOSE)"},
};

static HWND target_windows[MAX_TARGET_WINDOWS];
static int target_count;
static DWORD own_pid;
static int is_verbose = true;

static BOOL CALLBACK enum_callback(HWND hwnd, LPARAM param) {
	UNUSED(param);

	DWORD window_pid;
	
	// Exclude own process
	GetWindowThreadProcessId(hwnd, &window_pid);
	if (window_pid == own_pid) {
		return TRUE;
	}

	// Skip hidden windows
	if (!IsWindowVisible(hwnd)) {
		return TRUE;
	}

	// Skip windows with no title
	char title[MAX_WINDOW_TITLE_LEN] = {0};
	GetWindowTextA(hwnd, title, sizeof(title));

	if (title[0] == '\0') {
		return TRUE;
	}

	// Store window handle if room is available
	if (target_count < MAX_TARGET_WINDOWS) {
		target_windows[target_count] = hwnd;

		if (is_verbose) {
			char class_name[MAX_CLASS_NAME_LEN] = {0};
			GetClassNameA(hwnd, class_name, sizeof(class_name));

			printf("Eligible window num [%s] found: hwnd=%p, pid=%-6lu, class=\"%s\", title=\"%s\"\n",
					target_count, (void *)hwnd, (unsigned long)window_pid, class_name, title);
		}

		target_count++;
	}

	return TRUE;
}

static void enumerate_targets(void) {
	target_count = 0;
	EnumWindows(enum_callback, 0);
}

static void send_ime_messages(ImeMessage *ime_messages, int message_count) {
	enumerate_targets();

	if (target_count == 0) {
		if (is_verbose) {
			printf("No eligible windows found.\n");
		}
		return;
	}

	for (int win_i = 0; win_i < target_count; win_i++) {
		HWND target = target_windows[win_i];

		for (int msg_i = 0; msg_i < message_count; msg_i++) {
			ImeMessage *ime_msg = &ime_messages[msg_i];

			if (is_verbose) {
				printf("    -> target=%p, message=\"%s\"\n", (void *)target, ime_msg->description);
			}
			
			SendMessageTimeoutW(target, ime_msg->message_id, ime_msg->wparam, ime_msg->lparam, SMTO_ABORTIFHUNG, SEND_TIMEOUT_MS, NULL);
		}
	}

	if (is_verbose) {
		printf("IME message dispatch finished.\n");
	}
}

const char *programmode_to_string(enum ProgramModeEnum value) {
	switch (value) {
		case PROGRAM_MODE_ONCE:
			return "PROGRAM_MODE_ONCE";
		case PROGRAM_MODE_HOTKEY:
			return "PROGRAM_MODE_HOTKEY";
		case PROGRAM_MODE_PERIODIC:
			return "PROGRAM_MODE_PERIODIC";
		case PROGRAM_MODE_SPECIFIC:
			return "PROGRAM_MODE_SPECIFIC";
		default:
			return "Unknown mode";
	}
}

static void print_usage(const char *program_name) {
	printf(
        "Usage: %s [mode] [options]\n\n"
        "Modes (pick one):\n"
        "  --once         Send immediately, exit           (test)\n"
        "  --hotkey       Send on F12, Escape to quit      (manual fix)\n"
        "  --periodic [N] Send every N ms, default 2000    (auto fix)\n"
        "\n"
        "Options:\n"
        "  --all          Also send WM_IME_SETCONTEXT / WM_IME_NOTIFY\n"
        "  --quiet        Suppress per-send output\n"
        "  --hwnd 0xH     Target a specific window handle\n"
        "  --help         This message\n",
        program_name
    );
}

int main(int argc, char **argv) {
	own_pid = GetCurrentProcessId();

	enum ProgramModeEnum mode = PROGRAM_MODE_ONCE;
	bool use_all = false;
	int interval_ms = DEFAULT_INTERVAL_MS;
	HWND specific_hwnd = NULL;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--once") == 0) {
			mode = PROGRAM_MODE_ONCE;
		} else if (strcmp(argv[i], "--hotkey") == 0) {
			mode = PROGRAM_MODE_HOTKEY;
		} else if (strcmp(argv[i], "--periodic") == 0) {
			mode = PROGRAM_MODE_PERIODIC;
			if (i + 1 < argc && argv[i + 1][0] != '-') {
				interval_ms = atoi(argv[++i]);
				if (interval_ms < MINIMUM_INTERVAL_MS) {
					interval_ms = DEFAULT_INTERVAL_MS;
				}
			}
		} else if (strcmp(argv[i], "--all") == 0) {
			use_all = true;
		} else if (strcmp(argv[i], "--quiet") == 0) {
			is_verbose = false;
		} else if (strcmp(argv[i], "--hwnd") == 0 && i + 1 < argc) {
			specific_hwnd = (HWND)(uintptr_t)strtoull(argv[++i], NULL, 16);
			mode = PROGRAM_MODE_SPECIFIC;
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			print_usage(argv[0]);
			return 0;
		}
	}

	ImeMessage *active_messages;
	int active_message_count;

	if (use_all) {
		active_messages = imemsg_all_ime_messages;
		// pointer math
		active_message_count = (int)(sizeof(imemsg_all_ime_messages) / sizeof(imemsg_all_ime_messages[0]));
	} else {
		active_messages = imemsg_end_composition_only;
		active_message_count = 1;
	}

	printf("### Cold War IME Fix ###\n");
	printf("Messages to send: %s\n", use_all ? "all": "WM_IME_ENDCOMPOSITION");
	printf("Program mode: %s\n\n\n", programmode_to_string(mode));

	if (mode == PROGRAM_MODE_SPECIFIC && specific_hwnd != NULL) {
		printf("Target HWND: %p\n", (void *)specific_hwnd);
		for (int i = 0; i < active_message_count; i++) {
			ImeMessage *active_message = &active_messages[i];

			printf("    -> message=\"%s\"\n", active_message->description);
			SendMessageTimeoutW(specific_hwnd, active_message->message_id, active_message->wparam, active_message->lparam, SMTO_ABORTIFHUNG, SEND_TIMEOUT_MS, NULL);
		}
		printf("IME message dispatch finished.\n");
		return 0;
	}

	if (mode == PROGRAM_MODE_ONCE) {
		send_ime_messages(active_messages, active_message_count);
		return 0;
	}

	if (mode == PROGRAM_MODE_HOTKEY) {
		for (;;) {
			if (GetAsyncKeyState(VK_F12) & 1) {
				printf("Received F12 signal. Sending IME messages.\n");
				send_ime_messages(active_messages, active_message_count);
				printf("\n");
			}

			if (GetAsyncKeyState(VK_ESCAPE) & 1) {
				break;
			}
			Sleep(HOTKEY_POLL_MS);
		}
		return 0;
	}

	if (mode == PROGRAM_MODE_PERIODIC) {
		printf("Interval: %d ms. CTRL+C to stop.\n\n", interval_ms);
		if (is_verbose) {
			printf("Initial scan:\n");
		}
		send_ime_messages(active_messages, active_message_count);

		is_verbose = false;
		for (;;) {
			Sleep(interval_ms);
			send_ime_messages(active_messages, active_message_count);
		}
		return 0;
	}
}
