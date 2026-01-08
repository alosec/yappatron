"""Context detection - determine if a text input is focused."""

import subprocess
from dataclasses import dataclass

# macOS specific imports
try:
    from AppKit import NSWorkspace
    from Quartz import (
        CGWindowListCopyWindowInfo,
        kCGNullWindowID,
        kCGWindowListOptionOnScreenOnly,
    )

    HAS_MACOS = True
except ImportError:
    HAS_MACOS = False


@dataclass
class FocusedApp:
    """Information about the currently focused application."""

    name: str
    bundle_id: str | None
    window_title: str | None


@dataclass
class InputContext:
    """Context about the current input state."""

    has_text_input: bool
    app: FocusedApp | None
    is_browser: bool
    is_terminal: bool
    is_editor: bool


class ContextDetector:
    """Detect the current input context on macOS."""

    # Apps known to have text inputs
    BROWSER_BUNDLES = {
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  # Arc
    }

    TERMINAL_BUNDLES = {
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "com.github.wez.wezterm",
    }

    EDITOR_BUNDLES = {
        "com.microsoft.VSCode",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.apple.dt.Xcode",
        "org.vim.MacVim",
        "com.cursor.Cursor",
    }

    # Apps where we should always output (known text-heavy apps)
    TEXT_APP_BUNDLES = {
        "com.apple.Notes",
        "com.apple.TextEdit",
        "com.notion.id",
        "com.linear.Linear",
        "com.tinyspeck.slackmacgap",  # Slack
        "com.hnc.Discord",
    }

    def __init__(self):
        if not HAS_MACOS:
            print("Warning: macOS APIs not available, context detection limited")

    def get_focused_app(self) -> FocusedApp | None:
        """Get information about the currently focused application."""
        if not HAS_MACOS:
            return None

        try:
            workspace = NSWorkspace.sharedWorkspace()
            active_app = workspace.frontmostApplication()

            if active_app:
                return FocusedApp(
                    name=active_app.localizedName(),
                    bundle_id=active_app.bundleIdentifier(),
                    window_title=self._get_window_title(active_app.processIdentifier()),
                )
        except Exception as e:
            print(f"Error getting focused app: {e}")

        return None

    def _get_window_title(self, pid: int) -> str | None:
        """Get the title of the focused window for a process."""
        if not HAS_MACOS:
            return None

        try:
            windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)

            for window in windows:
                if window.get("kCGWindowOwnerPID") == pid:
                    return window.get("kCGWindowName")
        except Exception:
            pass

        return None

    def get_context(self) -> InputContext:
        """Get the current input context."""
        app = self.get_focused_app()

        if not app:
            return InputContext(
                has_text_input=True,  # Assume yes if we can't detect
                app=None,
                is_browser=False,
                is_terminal=False,
                is_editor=False,
            )

        bundle = app.bundle_id or ""

        is_browser = bundle in self.BROWSER_BUNDLES
        is_terminal = bundle in self.TERMINAL_BUNDLES
        is_editor = bundle in self.EDITOR_BUNDLES
        is_text_app = bundle in self.TEXT_APP_BUNDLES

        # Heuristic: assume text input is available in these apps
        has_text_input = is_browser or is_editor or is_text_app or is_terminal

        return InputContext(
            has_text_input=has_text_input,
            app=app,
            is_browser=is_browser,
            is_terminal=is_terminal,
            is_editor=is_editor,
        )

    def should_stream_output(self) -> bool:
        """Determine if we should stream output to the current context.

        Returns:
            True if we should stream keystrokes, False if we should buffer
        """
        context = self.get_context()
        return context.has_text_input


class AccessibilityContextDetector(ContextDetector):
    """Enhanced context detection using macOS Accessibility APIs.

    This can detect if an actual text field is focused, not just the app.
    Requires Accessibility permissions.
    """

    def __init__(self):
        super().__init__()
        self._has_accessibility = self._check_accessibility()

    def _check_accessibility(self) -> bool:
        """Check if we have accessibility permissions."""
        try:
            # Try to use accessibility APIs
            result = subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to get name of first process',
                ],
                capture_output=True,
                timeout=2,
            )
            return result.returncode == 0
        except Exception:
            return False

    def is_text_field_focused(self) -> bool:
        """Check if a text field is currently focused.

        This uses AppleScript/Accessibility to check the focused UI element.
        """
        if not self._has_accessibility:
            # Fall back to app-based heuristic
            return self.should_stream_output()

        try:
            script = """
            tell application "System Events"
                set frontApp to first application process whose frontmost is true
                set focusedElement to focused of frontApp
                if focusedElement is not missing value then
                    set elementRole to role of focusedElement
                    if elementRole is in {"AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"} then
                        return "true"
                    end if
                end if
                return "false"
            end tell
            """
            result = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True,
                text=True,
                timeout=1,
            )
            return result.stdout.strip() == "true"
        except Exception:
            # Fall back to app-based heuristic
            return self.should_stream_output()

    def should_stream_output(self) -> bool:
        """Determine if we should stream output.

        Uses accessibility to check for actual text field focus.
        """
        if self._has_accessibility:
            return self.is_text_field_focused()
        return super().should_stream_output()
