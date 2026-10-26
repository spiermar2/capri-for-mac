import AppKit

extension AppDelegate {
    @objc func showChatGPTAccount() {
        if let window = chatGPTAccountWindow {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Capri · ChatGPT"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua); window.backgroundColor = ink
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 420)); window.contentView = view
        view.addSubview(label("CAPRI // CHATGPT", frame: NSRect(x: 24, y: 369, width: 450, height: 25), size: 18, color: cyan))
        view.addSubview(label("Use your ChatGPT plan", frame: NSRect(x: 24, y: 338, width: 450, height: 25), size: 14))
        view.addSubview(label("Eligible replies use your ChatGPT plan or credits balance.\nYour messages and recent chat context are sent to OpenAI.\nThis does not import your other ChatGPT conversations.", frame: NSRect(x: 24, y: 275, width: 450, height: 60), size: 11, color: .lightGray))
        let status = label(ChatGPTAuth.shared.statusDescription, frame: NSRect(x: 24, y: 207, width: 450, height: 60), size: 11, color: cyan)
        view.addSubview(status); chatGPTStatus = status
        let signIn = NSButton(title: "Continue with ChatGPT", target: self, action: #selector(connectChatGPT))
        signIn.bezelStyle = .rounded; signIn.frame = NSRect(x: 24, y: 170, width: 292, height: 32)
        view.addSubview(signIn); chatGPTSignInButton = signIn
        let signOut = NSButton(title: "Sign out", target: self, action: #selector(disconnectChatGPT))
        signOut.bezelStyle = .rounded; signOut.frame = NSRect(x: 328, y: 170, width: 148, height: 32)
        signOut.isEnabled = ChatGPTAuth.shared.isSignedIn; view.addSubview(signOut); chatGPTSignOutButton = signOut
        let picker = NSPopUpButton(frame: NSRect(x: 24, y: 126, width: 452, height: 26))
        picker.addItem(withTitle: "GPT-6.1 Sol · connect to verify access")
        picker.isEnabled = false; picker.target = self; picker.action = #selector(chatGPTModelChanged)
        picker.setAccessibilityLabel("ChatGPT model"); view.addSubview(picker); chatGPTModelPicker = picker
        let refresh = NSButton(title: "Refresh models", target: self, action: #selector(refreshChatGPTModels))
        refresh.bezelStyle = .rounded; refresh.frame = NSRect(x: 24, y: 81, width: 140, height: 30); view.addSubview(refresh)
        let another = NSButton(title: "Switch account…", target: self, action: #selector(connectAnotherChatGPT))
        another.bezelStyle = .rounded; another.frame = NSRect(x: 174, y: 81, width: 146, height: 30); view.addSubview(another)
        let usage = NSButton(title: "Manage usage", target: self, action: #selector(manageChatGPTUsage))
        usage.bezelStyle = .rounded; usage.frame = NSRect(x: 330, y: 81, width: 146, height: 30); view.addSubview(usage)
        view.addSubview(label("Credentials stay in macOS Keychain. Sign out removes this\napp's connection. Voice is configured separately in Settings.", frame: NSRect(x: 24, y: 20, width: 452, height: 46), size: 10, color: .lightGray))
        chatGPTAccountWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if ChatGPTAuth.shared.isSignedIn { refreshChatGPTModels() }
    }

    @objc func connectChatGPT() {
        beginChatGPTSignIn(addAccount: false)
    }

    @objc func connectAnotherChatGPT() {
        guard chatGPTAccountTask == nil else { return }
        beginChatGPTSignIn(addAccount: true)
    }

    func beginChatGPTSignIn(addAccount: Bool) {
        if chatGPTAccountTask != nil {
            chatGPTAccountGeneration += 1
            ChatGPTAuth.shared.cancelSignIn(); chatGPTAccountTask?.cancel(); chatGPTAccountTask = nil
            chatGPTSignInButton?.title = "Continue with ChatGPT"
            chatGPTSignOutButton?.isEnabled = ChatGPTAuth.shared.isSignedIn
            updateBrainSettings()
            chatGPTStatus?.stringValue = "Sign-in cancelled."
            return
        }
        chatGPTStatus?.stringValue = "Finish signing in and approving Capri in your browser."
        chatGPTSignInButton?.title = "Cancel sign-in"
        chatGPTSignOutButton?.isEnabled = false
        chatGPTAccountGeneration += 1; let operation = chatGPTAccountGeneration
        chatGPTAccountTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.chatGPTAccountGeneration == operation {
                self.chatGPTAccountTask = nil
                self.chatGPTSignInButton?.title = "Continue with ChatGPT"
                self.chatGPTSignOutButton?.isEnabled = ChatGPTAuth.shared.isSignedIn
                self.updateBrainSettings()
                }
            }
            do {
                try await ChatGPTAuth.shared.signIn(addAccount: addAccount)
                try Task.checkCancellation()
                guard ChatGPTAuth.shared.hasPlanAccess else { throw ChatGPTAuthError.permissionMissing }
                self.selectChatGPTBackend()
                self.chatGPTStatus?.stringValue = ChatGPTAuth.shared.statusDescription
                if !self.defaults.bool(forKey: "chatGPTPlanWelcomeSeen") {
                    let welcome = NSAlert()
                    welcome.messageText = "You're using your ChatGPT plan"
                    welcome.informativeText = "Eligible AI replies in Capri use your ChatGPT plan or credits balance. You can manage Capri's usage in ChatGPT settings. Your other ChatGPT conversations are not imported."
                    welcome.addButton(withTitle: "Got it")
                    self.defaults.set(true, forKey: "chatGPTPlanWelcomeSeen")
                    if let window = self.chatGPTAccountWindow { await welcome.beginSheetModal(for: window) }
                }
                try Task.checkCancellation()
                try await self.loadChatGPTModels()
            } catch is CancellationError {
                if self.chatGPTAccountGeneration == operation { self.chatGPTStatus?.stringValue = "Sign-in cancelled." }
            } catch {
                if self.chatGPTAccountGeneration == operation { self.chatGPTStatus?.stringValue = error.localizedDescription }
            }
        }
    }

    @objc func disconnectChatGPT() {
        chatGPTAccountGeneration += 1
        chatGPTAccountTask?.cancel(); chatGPTAccountTask = nil
        ChatGPTAuth.shared.cancelSignIn()
        generation += 1; chatTask?.cancel(); brain.reset(); finishRequest()
        do {
            try ChatGPTAuth.shared.signOut()
            chatGPTStatus?.stringValue = "Signed out of Capri."
            chatGPTSignOutButton?.isEnabled = false
            chatGPTSignInButton?.title = "Continue with ChatGPT"
            chatGPTModels = []; chatGPTModelPicker?.isEnabled = false
            updateBrainSettings(); setReply("Connect ChatGPT in Settings when you're ready.", state: "CAPRI // DISCONNECTED")
        } catch { chatGPTStatus?.stringValue = error.localizedDescription }
    }

    @objc func refreshChatGPTModels() {
        guard chatGPTAccountTask == nil else { return }
        guard ChatGPTAuth.shared.isSignedIn else { chatGPTStatus?.stringValue = "Continue with ChatGPT first."; return }
        chatGPTStatus?.stringValue = "Checking models available to your account…"
        chatGPTAccountGeneration += 1; let operation = chatGPTAccountGeneration
        chatGPTAccountTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.chatGPTAccountGeneration == operation { self.chatGPTAccountTask = nil; self.updateBrainSettings() } }
            do { try await self.loadChatGPTModels() }
            catch is CancellationError { }
            catch { if self.chatGPTAccountGeneration == operation { self.chatGPTStatus?.stringValue = error.localizedDescription } }
        }
    }

    func loadChatGPTModels() async throws {
        let models = try await brain.chatGPT.availableModels()
        try Task.checkCancellation()
        chatGPTModels = models
        chatGPTModelPicker?.removeAllItems()
        for model in models { chatGPTModelPicker?.addItem(withTitle: model.displayName) }
        if let index = models.firstIndex(where: { $0.id == brain.chatGPTModel }) {
            chatGPTModelPicker?.selectItem(at: index)
            chatGPTStatus?.stringValue = "Connected · Using ChatGPT plan\n\(models[index].displayName) selected."
        } else {
            chatGPTModelPicker?.select(nil)
            chatGPTStatus?.stringValue = "Connected, but \(brain.chatGPTModel) wasn't listed.\nChoose an available model below."
        }
        chatGPTModelPicker?.isEnabled = !models.isEmpty
    }

    @objc func chatGPTModelChanged(_ sender: NSPopUpButton) {
        guard chatGPTModels.indices.contains(sender.indexOfSelectedItem) else { return }
        let model = chatGPTModels[sender.indexOfSelectedItem]
        generation += 1; chatTask?.cancel(); finishRequest()
        brain.chatGPTModel = model.id; defaults.set(model.id, forKey: "chatGPTModel")
        selectChatGPTBackend(); chatGPTStatus?.stringValue = "Connected · Using ChatGPT plan\n\(model.displayName) selected."
    }

    func selectChatGPTBackend() {
        generation += 1; chatTask?.cancel(); finishRequest(); brain.reset()
        brain.backend = .chatGPT; defaults.set("chatgpt", forKey: "backend")
        backendPicker?.selectItem(at: 0); updateBrainSettings()
        setReply("ChatGPT link connected. What are we getting into?", state: "CAPRI // ONLINE")
    }

    @objc func manageChatGPTUsage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!)
    }
}
