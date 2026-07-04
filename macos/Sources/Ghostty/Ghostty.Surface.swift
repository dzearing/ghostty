import GhosttyKit

extension Ghostty {
    /// Represents a single surface within Ghostty.
    ///
    /// NOTE(mitchellh): This is a work-in-progress class as part of a general refactor
    /// of our Ghostty data model. At the time of writing there's still a ton of surface
    /// functionality that is not encapsulated in this class. It is planned to migrate that
    /// all over.
    ///
    /// Wraps a `ghostty_surface_t`
    final class Surface: Sendable {
        private let surface: ghostty_surface_t

        /// An opaque object whose lifetime must extend until AFTER this surface is
        /// freed. For a REMOTE surface this is the `RemoteConnection` strong owner:
        /// `ghostty_surface_free` joins the surface's IO thread, which runs the
        /// remote backend's `threadExit` → `detachChannel` on the shared connection.
        /// Because the free below is DEFERRED to a detached task (deinit is not on
        /// the main actor), the connection could otherwise be freed first — a
        /// use-after-free on the connection's channel table. Capturing this token in
        /// the same task keeps the connection alive across the free. Nil for local
        /// surfaces. Typed `AnyObject` to avoid a Ghostty→Features module dependency.
        private let connectionKeepAlive: AnyObject?

        /// Read the underlying C value for this surface. This is unsafe because the value will be
        /// freed when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t {
            surface
        }

        /// Initialize from the C structure. `connectionKeepAlive` is retained until
        /// after the surface is freed (see the property doc) — pass the owning
        /// `RemoteConnection` for remote surfaces, nil for local.
        init(cSurface: ghostty_surface_t, connectionKeepAlive: AnyObject? = nil) {
            self.surface = cSurface
            self.connectionKeepAlive = connectionKeepAlive
        }

        deinit {
            // deinit is not guaranteed to happen on the main actor and our API
            // calls into libghostty must happen there so we capture the surface
            // value so we don't capture `self` and then we detach it in a task.
            // We can't wait for the task to succeed so this will happen sometime
            // but that's okay.
            //
            // We ALSO capture `connectionKeepAlive` so the shared remote connection
            // (if any) is guaranteed to outlive `ghostty_surface_free` — that call
            // joins the IO thread, which detaches this pane's channel ON the
            // connection. Releasing it only after the free closes the teardown
            // use-after-free.
            let surface = self.surface
            let keepAlive = self.connectionKeepAlive
            Task.detached { @MainActor in
                ghostty_surface_free(surface)
                // Keep the connection owner alive until the free above completes,
                // then drop it (this is the last reference for the final surface).
                _ = keepAlive
            }
        }

        /// Write raw bytes directly to the PTY without paste encoding or
        /// control character stripping. Used by +send-keys.
        @MainActor
        func writePtyRaw(_ text: String) {
            let len = text.utf8CString.count
            if len == 0 { return }

            text.withCString { ptr in
                ghostty_surface_write_pty(surface, ptr, UInt(len - 1))
            }
        }

        /// Send text to the terminal as if it was typed. This doesn't send the key events so keyboard
        /// shortcuts and other encodings do not take effect.
        @MainActor
        func sendText(_ text: String) {
            let len = text.utf8CString.count
            if len == 0 { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        @MainActor
        func sendKeyEvent(_ event: Input.KeyEvent) {
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Check if a key event matches a keybinding.
        ///
        /// This checks whether the given key event would trigger a keybinding in the terminal.
        /// If it matches, returns the binding flags indicating properties of the matched binding.
        ///
        /// - Parameter event: The key event to check
        /// - Returns: The binding flags if a binding matches, or nil if no binding matches
        @MainActor
        func keyIsBinding(_ event: ghostty_input_key_s) -> Input.BindingFlags? {
            var flags = ghostty_binding_flags_e(0)
            guard ghostty_surface_key_is_binding(surface, event, &flags) else { return nil }
            return Input.BindingFlags(cFlags: flags)
        }

        /// See `keyIsBinding(_ event: ghostty_input_key_s)`.
        @MainActor
        func keyIsBinding(_ event: Input.KeyEvent) -> Input.BindingFlags? {
            event.withCValue { keyIsBinding($0) }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        @MainActor
        var mouseCaptured: Bool {
            ghostty_surface_mouse_captured(surface)
        }

        /// The PID of the foreground process group attached to the PTY.
        @MainActor
        var foregroundPID: Int? {
            let pid = ghostty_surface_foreground_pid(surface)
            guard pid != 0 else { return nil }
            return Int(exactly: pid)
        }

        /// The PTY device name for this surface.
        @MainActor
        var ttyName: String? {
            let ttyName = AllocatedString(ghostty_surface_tty_name(surface)).string
            return ttyName.isEmpty ? nil : ttyName
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        @MainActor
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods)
        }

        /// Send a mouse position event to the terminal.
        ///
        /// This reports the current mouse position to the terminal, which may be used
        /// for mouse tracking, hover effects, or other position-dependent features.
        /// The terminal will only receive these events if mouse reporting is enabled.
        ///
        /// - Parameter event: The mouse position event to send to the terminal
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods)
        }

        /// Send a mouse scroll event to the terminal.
        ///
        /// This sends scroll wheel input to the terminal with delta values for both
        /// horizontal and vertical scrolling, along with precision and momentum information.
        /// The terminal processes this according to its scroll handling configuration.
        ///
        /// - Parameter event: The mouse scroll event to send to the terminal
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            ghostty_surface_mouse_scroll(
                surface,
                event.x,
                event.y,
                event.mods.cScrollMods)
        }

        /// Perform a keybinding action.
        ///
        /// The action can be any valid keybind parameter. e.g. `keybind = goto_tab:4`
        /// you can perform `goto_tab:4` with this.
        ///
        /// Returns true if the action was performed. Invalid actions return false.
        @MainActor
        func perform(action: String) -> Bool {
            let len = action.utf8CString.count
            if len == 0 { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }
    }
}
