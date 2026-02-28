import SwiftUI
import UIKit
import PDFKit
import ZIPFoundation

/// 简单的 Chatbot 页面：展示多轮对话，并调用大模型应答
struct ChatView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var store: ScanStore

    /// 初始提问内容
    let initialQuestion: String
    /// 回到首页
    var onBackHome: (() -> Void)?

    @State private var messages: [ChatMessageRecord] = []
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var isShowingAttachmentSheet: Bool = false
    @State private var isShowingAlbumPicker: Bool = false
    @State private var isShowingDocumentPicker: Bool = false
    @State private var attachedImageCount: Int = 0
    @State private var attachedFileNames: [String] = []
    @State private var sessionID: UUID = UUID()
    @State private var isShowingDrawer: Bool = false
    @State private var attachments: [AttachmentChip] = []
    /// 每条用户消息对应的一次性附件预览，仅用于当前会话 UI 展示，不做持久化
    @State private var messageAttachments: [UUID: [AttachmentChip]] = [:]
    /// 当前预览的大图
    @State private var imagePreviewItem: ImagePreviewItem?
    /// 当前预览的文件（PDF/Word）
    @State private var filePreviewItem: FilePreviewItem?
    @State private var alertMessage: String?
    /// 当前正在运行的 Agent 任务，用于支持「停止」按钮取消
    @State private var currentAgentTask: Task<Void, Never>? = nil
    /// 停止按钮的呼吸动画状态
    @State private var isStopPulsing: Bool = false
    /// 控制输入框的键盘焦点
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    messageListView
                    Divider()
                    attachmentsBar
                    inputBar
                }

                historyDrawer
            }
            .navigationTitle("学习问答")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let onBackHome {
                        Button(L10n.homeBackHome) {
                            onBackHome()
                        }
                        .foregroundStyle(AppTheme.accentBlue)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            isShowingDrawer.toggle()
                        }
                    } label: {
                        Image("lishijilu")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 20, height: 20)
                    }
                }
            }
        }
        .onAppear {
            if messages.isEmpty {
                // 首次进入：以新的会话 ID 开始；如果有初始问题，则自动发送一次
                sessionID = UUID()
                let trimmed = initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    inputText = trimmed
                    sendCurrentMessage()
                }
            }
            // 轻微延迟后自动聚焦输入框，确保软键盘弹出
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !isShowingAlbumPicker && !isShowingDocumentPicker {
                    isInputFocused = true
                }
            }
        }
        .confirmationDialog("添加附件", isPresented: $isShowingAttachmentSheet, titleVisibility: .visible) {
            Button("从相册选择") {
                isShowingAlbumPicker = true
                isShowingAttachmentSheet = false
            }
            Button("从文件中选择") {
                isShowingDocumentPicker = true
                isShowingAttachmentSheet = false
            }
            Button(L10n.cancel, role: .cancel) {}
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            PhotoLibraryPicker(
                onImagePicked: { image in
                    if let image {
                        Task {
                            await handleNewImageAttachment(image)
                        }
                    }
                    isShowingAlbumPicker = false
                },
                onDismiss: {
                    isShowingAlbumPicker = false
                }
            )
        }
        .sheet(isPresented: $isShowingDocumentPicker) {
            DocumentPicker(
                onPicked: { urls in
                    let unsupported = urls.filter {
                        let ext = $0.pathExtension.lowercased()
                        return ext != "pdf" && ext != "docx"
                    }
                    if !unsupported.isEmpty {
                        alertMessage = L10n.chatUnsupportedFileType
                    }
                    let supported = urls.filter {
                        let ext = $0.pathExtension.lowercased()
                        return ext == "pdf" || ext == "docx"
                    }
                    for url in supported {
                        let ext = url.pathExtension.lowercased()
                        let name = url.deletingPathExtension().lastPathComponent
                        // 将选中的文档复制到应用沙盒中，避免后续访问权限或路径失效问题
                        guard let localURL = copyDocumentToChatDir(originalURL: url) else { continue }
                        attachedFileNames.append(localURL.lastPathComponent)
                        let title = name
                        let suggestions = [
                            "详细总结《\(name)》文档内容",
                            "为《\(name)》生成简短摘要"
                        ]
                        if ext == "pdf" {
                            var att = AttachmentChip.pdf(title: title, suggestions: suggestions, fileURL: localURL)
                            // 先追加到附件列表，再异步生成 PDF 每页图片
                            attachments.append(att)
                            generatePdfPageImages(for: att.id, fileURL: localURL, originalFileName: title)
                        } else {
                            let att = AttachmentChip.word(title: title, suggestions: suggestions, fileURL: localURL)
                            attachments.append(att)
                        }
                    }
                },
                onDismiss: {
                    isShowingDocumentPicker = false
                }
            )
        }
        .alert(L10n.alertTitle, isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button(L10n.alertOK, role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .fullScreenCover(item: $imagePreviewItem) { item in
            ImageViewer(image: item.image, allowZoomAndPan: true)
        }
        .fullScreenCover(item: $filePreviewItem) { item in
            if item.url.pathExtension.lowercased() == "pdf" {
                PDFViewer(url: item.url)
            } else {
                DocumentPreviewView(url: item.url) {
                    filePreviewItem = nil
                }
            }
        }
    }

    /// 消息列表区域：单独拆分，减轻 body 的类型推断复杂度
    private var messageListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { msg in
                        let attachmentsForMessage = messageAttachments[msg.id] ?? []
                        HStack {
                            if msg.role == .assistant {
                                ChatBubble(message: msg, isUser: false, attachments: [], onTapAttachment: nil)
                                Spacer(minLength: 40)
                            } else {
                                Spacer(minLength: 40)
                                ChatBubble(
                                    message: msg,
                                    isUser: true,
                                    attachments: attachmentsForMessage,
                                    onTapAttachment: { attachment in
                                        openAttachment(attachment)
                                    }
                                )
                            }
                        }
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
            .shadow(
                color: .black.opacity(AppTheme.cardShadowOpacity),
                radius: AppTheme.cardShadowRadius,
                x: 0,
                y: AppTheme.cardShadowY
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onTapGesture {
                isInputFocused = false
            }
        }
    }

    /// 输入框上方的附件缩略图区域
    @ViewBuilder
    private var attachmentsBar: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(attachments) { att in
                            AttachmentCard(
                                attachment: att,
                                onRemove: {
                                    attachments.removeAll { $0.id == att.id }
                                },
                                onTap: {
                                    openAttachment(att)
                                }
                            )
                        }
                        Button {
                            isShowingAttachmentSheet = true
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color(.tertiaryLabel), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    .frame(width: 72, height: 72)
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attachments.flatMap(\.suggestions), id: \.self) { suggestion in
                            Button {
                                inputText = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGray6))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// 底部输入区
    @ViewBuilder
    private var inputBar: some View {
        if !isShowingAlbumPicker && !isShowingDocumentPicker {
            HStack(spacing: 12) {
                Button {
                    isShowingAttachmentSheet = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                TextField("向张老师提问…", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isInputFocused)

                Button {
                    if isSending {
                        // 正在等待 Agent 响应：点击变为「停止」，取消当前任务
                        currentAgentTask?.cancel()
                        currentAgentTask = nil
                        isSending = false
                    } else {
                        sendCurrentMessage()
                    }
                } label: {
                    if isSending {
                        // 等待中：显示「停止」图标按钮
                        Image("tingzhi")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(.red)
                            .frame(width: 40, height: 40)
                            .scaleEffect(isStopPulsing ? 1.08 : 0.92)
                            .opacity(isStopPulsing ? 1.0 : 0.72)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isStopPulsing)
                            .onAppear {
                                isStopPulsing = true
                            }
                            .onDisappear {
                                isStopPulsing = false
                            }
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.accentBlue)
                    }
                }
                // 等待时允许点击「停止」，仅在空输入且未在发送时禁用
                .disabled(!isSending && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
    }

    /// 右侧历史会话抽屉
    @ViewBuilder
    private var historyDrawer: some View {
        if isShowingDrawer {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 0) {
                        // 顶部：新建会话
                        Button {
                            // 新建会话：清空当前对话与附件，重置输入与会话 ID，并收起抽屉
                            messages.removeAll()
                            attachments.removeAll()
                            attachedImageCount = 0
                            attachedFileNames = []
                            inputText = ""
                            sessionID = UUID()
                            withAnimation {
                                isShowingDrawer = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("新建会话")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)

                        Divider()

                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                let grouped = groupedSessions()
                                if !grouped.today.isEmpty {
                                    HistorySection(
                                        title: "今天",
                                        sessions: grouped.today,
                                        onSelect: { session in
                                            loadSession(session)
                                        },
                                        onDelete: { session in
                                            deleteSession(session)
                                        }
                                    )
                                }
                                if !grouped.thisWeek.isEmpty {
                                    HistorySection(
                                        title: "最近一周",
                                        sessions: grouped.thisWeek,
                                        onSelect: { session in
                                            loadSession(session)
                                        },
                                        onDelete: { session in
                                            deleteSession(session)
                                        }
                                    )
                                }
                                if !grouped.earlier.isEmpty {
                                    HistorySection(
                                        title: "更早",
                                        sessions: grouped.earlier,
                                        onSelect: { session in
                                            loadSession(session)
                                        },
                                        onDelete: { session in
                                            deleteSession(session)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        }
                    }
                    .frame(width: geo.size.width * 0.75, height: geo.size.height)
                    .background(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.25), radius: 10, x: -4, y: 0)
                }
                .background(
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation {
                                isShowingDrawer = false
                            }
                        }
                )
            }
            .transition(.move(edge: .trailing))
        }
    }

    private func sendCurrentMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        // 若已有请求在进行中，则不重复发送
        guard !isSending else { return }
        // 为当前这条消息记录一份附件快照，用于在对话气泡展示与持久化
        let attachmentsSnapshot = attachments

        // 构造附件元信息，用于写入持久化 ChatMessageRecord
        let attachmentMetas: [ChatAttachmentMeta]? = attachmentsSnapshot.isEmpty ? nil : attachmentsSnapshot.map { att in
            switch att.kind {
            case .image:
                // 对图片，同时保存缩略图在磁盘中的路径，方便历史会话恢复显示
                return ChatAttachmentMeta(
                    kind: .image,
                    title: att.title,
                    filePath: att.fileURL?.path,
                    pageImagePaths: nil
                )
            case .pdf:
                return ChatAttachmentMeta(
                    kind: .pdf,
                    title: att.title,
                    filePath: att.fileURL?.path,
                    pageImagePaths: att.pdfPageImagePaths
                )
            case .word:
                return ChatAttachmentMeta(
                    kind: .word,
                    title: att.title,
                    filePath: att.fileURL?.path,
                    pageImagePaths: nil
                )
            }
        }

        // 消息正文中不再显式附加附件说明，附件信息仅用于提示词上下文和本次消息的图片预览
        let userMsg = ChatMessageRecord(
            id: UUID(),
            role: .user,
            text: question,
            createdAt: Date(),
            attachments: attachmentMetas
        )

        // 为当前这条消息记录一份附件快照，用于在对话气泡中展示较大的缩略图
        if !attachmentsSnapshot.isEmpty {
            messageAttachments[userMsg.id] = attachmentsSnapshot
        }
        messages.append(userMsg)
        persistSession()
        inputText = ""
        attachedImageCount = 0
        attachedFileNames = []
        // 发送后关闭输入框上方的附件卡片
        attachments.removeAll()

        // 若之前有未完成任务，先取消
        currentAgentTask?.cancel()
        currentAgentTask = Task {
            await MainActor.run { isSending = true }
            defer {
                Task { @MainActor in
                    isSending = false
                    currentAgentTask = nil
                }
            }

            let enrichedAttachments = await enrichAttachmentsForPrompt(attachmentsSnapshot)
            if Task.isCancelled { return }
            await sendViaAgent(latestQuestion: question, attachmentsSnapshot: enrichedAttachments)
        }
    }

    @MainActor
    private func appendAssistantMessage(_ text: String) {
        let msg = ChatMessageRecord(role: .assistant, text: text, createdAt: Date())
        messages.append(msg)
        persistSession()
    }

    /// 调用大模型，根据当前错题和多轮对话上下文生成回答
    private func sendToModel(latestQuestion: String, attachmentsSnapshot: [AttachmentChip]) async {
        guard let cfg = settings.effectiveConfig() else { return }
        // 使用文本大模型判断是否为学习相关问题
        let isStudy = await isStudyRelated(latestQuestion, config: cfg)
        if !isStudy {
            await appendAssistantMessage("张老师只讨论学习相关问题！")
            return
        }

        if isSending { return }
        await MainActor.run { isSending = true }
        defer { Task { @MainActor in isSending = false } }

        let prompt = buildChatPrompt(userQuestion: latestQuestion, attachmentsSnapshot: attachmentsSnapshot)
        do {
            let reply = try await LLMService.chat(prompt: prompt, provider: settings.provider, config: cfg)
            let trimmed = sanitizeAssistantReply(reply)
            await appendAssistantMessage(trimmed)
        } catch {
            await appendAssistantMessage(error.localizedDescription)
        }
    }

    /// 使用轻量级 Agent 处理一次学习问答提问
    private func sendViaAgent(latestQuestion: String, attachmentsSnapshot: [AttachmentChip]) async {
        guard let cfg = settings.effectiveConfig() else { return }

        // 先沿用原来的「是否为学习相关问题」拦截逻辑
        let isStudy = await isStudyRelated(latestQuestion, config: cfg)
        if !isStudy {
            await appendAssistantMessage("张老师只讨论学习相关问题！")
            return
        }

        // 构造本轮 Agent 上下文
        let context = ChatAgentContext(
            question: latestQuestion,
            messages: messages,
            attachments: attachmentsSnapshot,
            notes: []
        )

        let tools: [ChatAgentTool] = [
            // 1) 将附件整体概要写入 notes
            AttachmentSummaryTool(),
            // 2) 当问题指向 PDF 文档中的具体题目时，在 PDF 渲染出的页面图片中查找并解析
            PdfQuestionExtractionTool(),
            // 3) 当问题指向 docx 文档中的具体题目时，抽取文本并进行针对性作答
            DocxQuestionExtractionTool(),
            // 4) 当问题指向图片附件中的具体题目时，直接在图片上用 VL 模型解析
            ImageQuestionExtractionTool()
        ]

        let agent = ChatAgent(settings: settings, store: store, tools: tools)
        let rawReply = await agent.answer(with: context)
        let cleaned = sanitizeAssistantReply(rawReply)
        await appendAssistantMessage(cleaned)
    }

    /// 从历史记录中加载会话：在主对话框中展示该会话，并继续沿用同一个会话 ID
    private func loadSession(_ session: ChatSession) {
        // 使用历史会话的消息与 ID
        messages = session.messages
        sessionID = session.id
        // 根据持久化的附件元信息重建每条消息的附件快照，用于 UI 展示
        messageAttachments.removeAll()
        for msg in session.messages {
            guard msg.role == .user, let metas = msg.attachments, !metas.isEmpty else { continue }
            var chips: [AttachmentChip] = []
            for meta in metas {
                switch meta.kind {
                case .image:
                    if let path = meta.filePath,
                       let img = UIImage(contentsOfFile: path) {
                        var chip = AttachmentChip.image(title: meta.title, suggestions: [], thumbnail: img)
                        chip.fileURL = URL(fileURLWithPath: path)
                        chips.append(chip)
                    } else {
                        // 历史图片：若无法还原原图，则使用占位图标与标题
                        chips.append(.image(title: meta.title, suggestions: [], thumbnail: nil))
                    }
                case .pdf:
                    let url = meta.filePath.map { URL(fileURLWithPath: $0) }
                    var chip = AttachmentChip.pdf(title: meta.title, suggestions: [], fileURL: url)
                    chip.pdfPageImagePaths = meta.pageImagePaths
                    chips.append(chip)
                case .word:
                    let url = meta.filePath.map { URL(fileURLWithPath: $0) }
                    chips.append(.word(title: meta.title, suggestions: [], fileURL: url))
                }
            }
            if !chips.isEmpty {
                messageAttachments[msg.id] = chips
            }
        }
        // 清理当前输入和附件，避免与历史会话混淆
        inputText = ""
        attachments.removeAll()
        attachedImageCount = 0
        attachedFileNames = []
        // 收起会话历史抽屉
        withAnimation {
            isShowingDrawer = false
        }
    }

    /// 处理附件点击：根据类型打开图片预览或文档预览
    private func openAttachment(_ attachment: AttachmentChip) {
        switch attachment.kind {
        case .image:
            if let img = attachment.thumbnail {
                imagePreviewItem = ImagePreviewItem(image: img)
            } else if let url = attachment.fileURL,
                      let img = UIImage(contentsOfFile: url.path) {
                imagePreviewItem = ImagePreviewItem(image: img)
            }
        case .pdf, .word:
            if let url = attachment.fileURL {
                filePreviewItem = FilePreviewItem(url: url)
            }
        }
    }

    /// 删除一个历史会话，包括其在当前视图中的展示
    private func deleteSession(_ session: ChatSession) {
        store.deleteChatSession(id: session.id)

        // 如果当前正在查看的是被删除的会话，则清空对话内容并重置为新会话
        if session.id == sessionID {
            messages.removeAll()
            attachments.removeAll()
            attachedImageCount = 0
            attachedFileNames = []
            inputText = ""
            sessionID = UUID()
        }
    }

    /// 将当前会话写入持久化存储
    private func persistSession() {
        guard !messages.isEmpty else { return }
        // 会话标题：取第一条用户消息的前 20 个字符
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? "学习问答" : String(trimmed.prefix(20))
            store.upsertChatSession(id: sessionID, title: title, messages: messages)
        }
    }

    /// 处理新上传的图片附件：生成缩略图、调用 VL 模型解析，并用文本模型生成推荐问题
    private func handleNewImageAttachment(_ image: UIImage) async {
        await MainActor.run {
            attachedImageCount += 1
            // 先插入一个占位附件，稍后填充解析与推荐问题
            let placeholder = AttachmentChip.image(title: "", suggestions: [], thumbnail: image)
            attachments.append(placeholder)
        }

        guard let cfg = settings.effectiveConfig() else { return }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }

        // 将图片缩略图保存到磁盘，供会话历史恢复时加载
        let thumbPath = try? saveImageThumbnail(image)
        if let thumbPath {
            await MainActor.run {
                if let idx = attachments.firstIndex(where: { $0.thumbnail === image }) {
                    attachments[idx].fileURL = URL(fileURLWithPath: thumbPath)
                }
            }
        }

        // 使用 VL 模型解析图片内容，得到 Markdown 描述
        let markdown: String
        do {
            markdown = try await LLMService.describeImage(imageJPEGData: data, provider: settings.provider, config: cfg)
        } catch {
            await MainActor.run {
                // 如果解析失败，至少保留缩略图
                if let idx = attachments.firstIndex(where: { $0.thumbnail === image }) {
                    attachments[idx].suggestions = []
                }
            }
            return
        }

        // 保存为 markdown 文件（失败不影响主逻辑）
        _ = try? saveImageMarkdown(markdown)

        // 基于解析内容生成推荐问题
        let suggestions = await generateImageSuggestions(from: markdown, config: cfg)

        await MainActor.run {
            if let idx = attachments.firstIndex(where: { $0.thumbnail === image }) {
                attachments[idx].suggestions = suggestions
                // title 可选地使用 markdown 第一行作为简短标题（不在 UI 展示，但可用于上下文）
                if let firstLine = markdown.split(separator: "\n").first {
                    attachments[idx].title = String(firstLine.prefix(30))
                }
                attachments[idx].markdown = markdown
            }
        }
    }

    /// 将图片解析内容保存为 markdown 文件
    private func saveImageMarkdown(_ markdown: String) throws -> String {
        let fm = FileManager.default
        let docs = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("camit_chat", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fileURL = dir.appendingPathComponent("image-\(UUID().uuidString).md")
        try markdown.data(using: .utf8)?.write(to: fileURL, options: [.atomic])
        return fileURL.path
    }

    /// 将图片附件缩略图保存为 jpg，供历史会话恢复时加载
    private func saveImageThumbnail(_ image: UIImage) throws -> String {
        let fm = FileManager.default
        let docs = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("camit_chat_images", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fileURL = dir.appendingPathComponent("img-\(UUID().uuidString).jpg")
        if let data = image.jpegData(compressionQuality: 0.8) {
            try data.write(to: fileURL, options: [.atomic])
        }
        return fileURL.path
    }

    /// 将 PDF 解析内容保存为 markdown 文件（analysis / summary）
    private func savePDFMarkdown(_ markdown: String, originalFileName: String, suffix: String) throws -> String {
        let fm = FileManager.default
        let docs = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("camit_chat_pdf", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let safeName = originalFileName.replacingOccurrences(of: "/", with: "_")
        let fileURL = dir.appendingPathComponent("\(safeName)-\(suffix)-\(UUID().uuidString).md")
        try markdown.data(using: .utf8)?.write(to: fileURL, options: [.atomic])
        return fileURL.path
    }

    /// 将 PDF 每一页渲染为图片文件，保存到沙盒，并记录路径到对应附件上
    private func generatePdfPageImages(for attachmentID: UUID, fileURL: URL, originalFileName: String) {
        Task.detached {
            guard let document = PDFDocument(url: fileURL) else { return }
            let pageCount = document.pageCount
            guard pageCount > 0 else { return }

            print("[camit][pdf] start render pages for \(originalFileName), total pages = \(pageCount)")
            var paths: [String] = []
            for index in 0..<pageCount {
                guard let page = document.page(at: index) else { continue }
                let pageBounds = page.bounds(for: .mediaBox)

                // 使用 UIGraphics 渲染为 UIImage
                let renderer = UIGraphicsImageRenderer(size: pageBounds.size)
                let img = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(pageBounds)
                    ctx.cgContext.translateBy(x: 0, y: pageBounds.size.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    ctx.cgContext.drawPDFPage(page.pageRef!)
                }

                if let data = img.jpegData(compressionQuality: 0.85),
                   let path = try? savePdfPageImageData(data, originalFileName: originalFileName, pageIndex: index + 1) {
                    paths.append(path)
                    print("[camit][pdf] saved page \(index + 1) image at \(path)")
                }
            }

            guard !paths.isEmpty else { return }

            await MainActor.run {
                if let idx = attachments.firstIndex(where: { $0.id == attachmentID }) {
                    attachments[idx].pdfPageImagePaths = paths
                    print("[camit][pdf] attachment \(attachmentID) updated with \(paths.count) page images")
                }
            }
        }
    }

    /// 保存单页 PDF 渲染图片到磁盘，返回文件路径
    private func savePdfPageImageData(_ data: Data, originalFileName: String, pageIndex: Int) throws -> String {
        let fm = FileManager.default
        let docs = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("camit_chat_pdf_pages", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let safeName = originalFileName.replacingOccurrences(of: "/", with: "_")
        let fileURL = dir.appendingPathComponent("\(safeName)-page\(pageIndex)-\(UUID().uuidString).jpg")
        try data.write(to: fileURL, options: [.atomic])
        return fileURL.path
    }

    /// 将通过文件选择器选中的文档复制到应用沙盒的 chat 目录，返回新的本地 URL
    private func copyDocumentToChatDir(originalURL: URL) -> URL? {
        do {
            let fm = FileManager.default
            let docs = try fm.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = docs.appendingPathComponent("camit_chat_docs", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let dest = dir.appendingPathComponent(originalURL.lastPathComponent)
            // 若已存在同名文件，先删除再复制，避免旧内容残留
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: originalURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// 在发送前，对附件进行富化：对 PDF 做文本提取与大模型解析，生成 markdown 内容和概要，并确保生成页面图片供题目抽取工具使用
    private func enrichAttachmentsForPrompt(_ attachments: [AttachmentChip]) async -> [AttachmentChip] {
        guard let cfg = settings.effectiveConfig() else { return attachments }
        guard !attachments.isEmpty else { return attachments }

        var result = attachments
        for idx in result.indices {
            let att = result[idx]
            guard att.kind == .pdf, let url = att.fileURL else { continue }

            let baseName = url.deletingPathExtension().lastPathComponent

            // 1) 确保已有 PDF 页面图片路径，供 PdfQuestionExtractionTool 使用
            if result[idx].pdfPageImagePaths == nil || result[idx].pdfPageImagePaths?.isEmpty == true {
                if let pagePaths = try? renderPdfPagesForPrompt(fileURL: url, originalFileName: baseName) {
                    result[idx].pdfPageImagePaths = pagePaths
                }
            }

            // 2) 若尚未生成解析与概要，则补充生成（用于上下文）
            if att.pdfAnalysisPath == nil || att.pdfSummaryPath == nil || att.markdown == nil {
                let (analysisMD, summaryMD) = await analyzePdfForPrompt(fileURL: url, title: att.title, config: cfg)
                if let analysisMD, let summaryMD {
                    let analysisPath = try? savePDFMarkdown(analysisMD, originalFileName: baseName, suffix: "analysis")
                    let summaryPath = try? savePDFMarkdown(summaryMD, originalFileName: baseName, suffix: "summary")

                    result[idx].markdown = summaryMD   // 用于提示词中的简要上下文
                    result[idx].pdfAnalysisPath = analysisPath
                    result[idx].pdfSummaryPath = summaryPath
                }
            }
        }
        return result
    }

    /// 为 Agent 富化阶段渲染 PDF 页面图片（与 generatePdfPageImages 类似，但同步返回路径数组）
    private func renderPdfPagesForPrompt(fileURL: URL, originalFileName: String, maxPages: Int = 8) throws -> [String] {
        guard let document = PDFDocument(url: fileURL) else { return [] }
        let pageCount = min(document.pageCount, maxPages)
        guard pageCount > 0 else { return [] }

        var paths: [String] = []
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)

            let renderer = UIGraphicsImageRenderer(size: pageBounds.size)
            let img = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(pageBounds)
                ctx.cgContext.translateBy(x: 0, y: pageBounds.size.height)
                ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                ctx.cgContext.drawPDFPage(page.pageRef!)
            }

            if let data = img.jpegData(compressionQuality: 0.85) {
                let path = try savePdfPageImageData(data, originalFileName: originalFileName, pageIndex: index + 1)
                paths.append(path)
            }
        }
        return paths
    }

    /// 提取 PDF 文本并调用大模型生成详细解析和概要（均为 markdown）
    private func analyzePdfForPrompt(
        fileURL: URL,
        title: String,
        config: any LLMConfigProtocol
    ) async -> (analysisMarkdown: String?, summaryMarkdown: String?) {
        guard let document = PDFDocument(url: fileURL) else { return (nil, nil) }
        let maxPages = min(document.pageCount, 12)  // 防止提示词过长
        var pieces: [String] = []
        for i in 0..<maxPages {
            guard let page = document.page(at: i),
                  let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            pieces.append("【第 \(i + 1) 页】\n\(text)")
        }
        let fullText = pieces.joined(separator: "\n\n---\n\n")
        let clipped = String(fullText.prefix(8000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, nil)
        }

        let analysisPrompt = """
你将看到一份 PDF 文档的部分或全部文字内容，文档标题为「\(title)」。

请从中提取对学习有帮助的结构化信息，并用 Markdown 输出，要求：
1. 使用二级、三级标题（##、###）组织内容；
2. 保留重要公式、关键术语和结论，可使用行内或代码块格式；
3. 按原文顺序分章节梳理，不要杜撰不存在的内容；
4. 输出语言保持与原文一致；如原文为英文，可在括号中补充简短中文解释。

====== 文档内容开始 ======
\(clipped)
====== 文档内容结束 ======
"""

        let summaryPrompt = """
下面是一份 PDF 文档的文字内容节选，文档标题为「\(title)」：

\(clipped)

请用中文为这份文档写一个简短概要，要求：
- 输出 Markdown 格式；
- 先给出 3～5 条要点列表（使用 - 项目符号），概括核心内容；
- 如有适合中学生的学习收获或建议，单独增加一节《学习提示》。
"""

        do {
            let analysis = try await LLMService.chat(
                prompt: analysisPrompt,
                provider: settings.provider,
                config: config
            )
            let summary = try await LLMService.chat(
                prompt: summaryPrompt,
                provider: settings.provider,
                config: config
            )
            return (analysis, summary)
        } catch {
            return (nil, nil)
        }
    }

    /// 使用文本大模型，根据图片解析 Markdown 生成推荐问题
    private func generateImageSuggestions(from markdown: String, config: any LLMConfigProtocol) async -> [String] {
        let prompt = """
下面是一张图片的 Markdown 描述，用于学习相关的问答：

\(markdown)

请从「学生可能会向老师提问」的角度，生成 2～3 个简短的问题：
- 一行一个问题；
- 不要编号，不要前缀；
- 每个问题不超过 20 个汉字；
- 问题要具体、与图片内容强相关。
"""
        do {
            let text = try await LLMService.chat(
                prompt: prompt,
                provider: settings.provider,
                config: config
            )
            let lines = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line -> String in
                    // 去掉可能的编号或项目符号
                    var t = line
                    if let range = t.range(of: #"^[-*\d\.\)\s]+"#, options: .regularExpression) {
                        t.removeSubrange(range)
                        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return String(t.prefix(20))
                }
            return Array(Set(lines)).prefix(3).map { $0 }
        } catch {
            return []
        }
    }

    /// 使用文本大模型判断问题是否与学习 / 课程相关
    private func isStudyRelated(_ text: String, config: any LLMConfigProtocol) async -> Bool {
        let prompt = """
你是一个分类助手，需要判断用户问题是否与「学生学习、课程、考试或各科知识」相关。

用户问题：
\"\(text)\"

如果问题与学生学习或各学科知识点相关，请只回答：study
如果明显与学习无关，请只回答：non-study
不要添加任何其他文字。
"""
        do {
            let reply = try await LLMService.chat(
                prompt: prompt,
                provider: settings.provider,
                config: config
            )
            let lower = reply.lowercased()
            if lower.contains("non-study") {
                return false
            }
            if lower.contains("study") || lower.contains("学习") {
                return true
            }
            // 模型回答异常时，默认按学习相关处理，避免误杀
            return true
        } catch {
            // 出错时回退为学习问题，保证功能可用
            return true
        }
    }

    /// 去掉模型回答前多余的「张老师:」等前缀，只保留内容本身
    private func sanitizeAssistantReply(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["张老师：", "张老师:", "老师：", "老师:"]
        for p in prefixes {
            if text.hasPrefix(p) {
                text = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return repairMarkdownAndLatex(text)
    }

    /// 对模型输出做温和修复：提升 Markdown 与 LaTeX 的渲染稳定性
    private func repairMarkdownAndLatex(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 常见控制字符导致的 LaTeX 损坏（\begin/\frac/\times 等）
        s = s.replacingOccurrences(of: "\u{0008}egin", with: "\\begin")
            .replacingOccurrences(of: "\u{0008}eta", with: "\\beta")
            .replacingOccurrences(of: "\u{000C}rac", with: "\\frac")
            .replacingOccurrences(of: "\u{0009}imes", with: "\\times")
            .replacingOccurrences(of: "\u{0009}ext", with: "\\text")
            .replacingOccurrences(of: "\u{0009}heta", with: "\\theta")
            .replacingOccurrences(of: "\u{0009}riangle", with: "\\triangle")

        // 列表符与标题补空格，避免 Markdown 解析失败
        s = regexReplace(s, pattern: #"(?m)^([\-*+])(\S)"#, template: "$1 $2")
        s = regexReplace(s, pattern: #"(?m)^(\d+\.)(\S)"#, template: "$1 $2")
        s = regexReplace(s, pattern: #"(?m)^(#{1,6})(\S)"#, template: "$1 $2")

        // 标题前补空行，避免与前文粘连
        s = regexReplace(s, pattern: #"(?m)(\S)\n(#{1,6}\s)"#, template: "$1\n\n$2")

        // 成对标记补全（缺失时在末尾补一个，优先保证可渲染）
        s = closeIfOdd(s, marker: "```", append: "\n```")
        s = closeIfOdd(s, marker: "**", append: "**")
        s = closeIfOdd(s, marker: "__", append: "__")
        s = closeIfOdd(s, marker: "~~", append: "~~")

        // 公式分隔符补全：先处理 $$，再处理剩余单个 $
        s = closeIfOdd(s, marker: "$$", append: "\n$$")
        let singleDollarCount = countUnescapedSingleDollar(in: s)
        if singleDollarCount % 2 != 0 {
            s += "$"
        }

        // 合并过多空行，保持阅读美观
        s = regexReplace(s, pattern: #"\n{3,}"#, template: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func regexReplace(_ input: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    private func closeIfOdd(_ input: String, marker: String, append: String) -> String {
        var s = input
        let count = s.components(separatedBy: marker).count - 1
        if count % 2 != 0 {
            s += append
        }
        return s
    }

    /// 统计未被转义的单个 $（不把 $$ 重复计入）
    private func countUnescapedSingleDollar(in input: String) -> Int {
        let chars = Array(input)
        var i = 0
        var count = 0
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    i += 2
                    continue
                }
                count += 1
            }
            i += 1
        }
        return count
    }

    /// 把所有会话按「今天」「最近一周」「更早」分段
    private func groupedSessions() -> (today: [ChatSession], thisWeek: [ChatSession], earlier: [ChatSession]) {
        let sessions = store.allChatSessions()
        let cal = Calendar.current
        let now = Date()
        return sessions.reduce(into: (today: [ChatSession](), thisWeek: [ChatSession](), earlier: [ChatSession]())) { acc, session in
            if cal.isDateInToday(session.updatedAt) {
                acc.today.append(session)
            } else if let weekAgo = cal.date(byAdding: .day, value: -7, to: now),
                      session.updatedAt >= weekAgo {
                acc.thisWeek.append(session)
            } else {
                acc.earlier.append(session)
            }
        }
    }

    /// 结合当前错题信息和多轮对话，构造发送给大模型的提示词
    private func buildChatPrompt(userQuestion: String, attachmentsSnapshot: [AttachmentChip]) -> String {
        let baseItems = store.items.filter {
            !$0.isArchived &&
            $0.isHomeworkOrExam &&
            !$0.imageFileNames.isEmpty
        }

        // 年级推测
        let recent = baseItems.sorted(by: { $0.createdAt > $1.createdAt })
        let currentGrade = recent.first?.grade.displayName ?? Grade.other.displayName

        // 科目统计与得分
        var subjectStats: [Subject: (total: Int, wrong: Int, scores: [Int])] = [:]
        var wrongQuestions: [PaperQuestion] = []

        for item in baseItems {
            let questions = item.questions.filter { $0.isQuestionItem }
            let wrong = questions.filter { $0.isWrong }
            wrongQuestions.append(contentsOf: wrong)

            var entry = subjectStats[item.subject] ?? (0, 0, [])
            entry.total += questions.count
            entry.wrong += wrong.count
            if let s = item.score {
                entry.scores.append(s)
            }
            subjectStats[item.subject] = entry
        }

        let subjectSummaryLines: [String] = subjectStats.keys.sorted { $0.displayName < $1.displayName }.map { subject in
            let stat = subjectStats[subject]!
            let accuracy: String
            if stat.total > 0 {
                let correct = max(0, stat.total - stat.wrong)
                let ratio = Int((Double(correct) / Double(stat.total) * 100).rounded())
                accuracy = "\(ratio)%"
            } else {
                accuracy = "未知"
            }
            let averageScore: String
            if !stat.scores.isEmpty {
                let avg = stat.scores.reduce(0, +) / stat.scores.count
                averageScore = "\(avg)"
            } else {
                averageScore = "暂无"
            }
            return "- 科目：\(subject.displayName)，客观题正确率约：\(accuracy)，近期试卷得分（若有）：\(averageScore)"
        }

        // 错题知识点简单摘要
        let wrongSummary: String = {
            guard !wrongQuestions.isEmpty else { return "暂无错题" }
            let maxQ = 10
            let slice = wrongQuestions.prefix(maxQ)
            let lines = slice.enumerated().map { idx, q in
                "错题\(idx + 1)：\(q.text.prefix(120))"
            }
            return lines.joined(separator: "\n")
        }()

        // 多轮对话历史（最近若干条）
        let recentMessages = messages.suffix(8)
        let historyLines: [String] = recentMessages.map { msg in
            let prefix: String = (msg.role == .user) ? "学生：" : "张老师："
            return prefix + msg.text
        }
        let historyBlock = historyLines.isEmpty ? "（暂无）" : historyLines.joined(separator: "\n")

        var context = "【当前年级】\(currentGrade)\n"
        if !subjectSummaryLines.isEmpty {
            context += "【各科情况概览】\n" + subjectSummaryLines.joined(separator: "\n") + "\n"
        }
        context += "【近期错题摘要】\n\(wrongSummary)\n"

        if !attachmentsSnapshot.isEmpty {
            let attachmentLines: [String] = attachmentsSnapshot.map { att in
                switch att.kind {
                case .image:
                    return "图片附件：\(att.title)"
                case .pdf:
                    return "PDF 文档附件：\(att.title)"
                case .word:
                    return "Word 文档附件：\(att.title)"
                }
            }
            context += "【当前会话附件】\n" + attachmentLines.joined(separator: "\n") + "\n"
        }

        // 将图片解析得到的 Markdown 内容加入上下文，供大模型参考
        let allImageMarkdown = attachmentsSnapshot
            .compactMap { $0.markdown }
            .joined(separator: "\n\n---\n\n")
        if !allImageMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 为避免提示词过长，可以适当截断
            let limited = String(allImageMarkdown.prefix(3000))
            context += "【图片解析内容】\n\(limited)\n"
        }

        return """
你是一位耐心、专业的中学学科辅导老师「张老师」，需要用自然、鼓励式的中文为学生提供一对一学习建议。

请严格遵守：
1. 结合下面提供的学生年级、各科情况、错题统计与对话历史来回答。
2. 回答务必简洁，用 1～3 句简短中文或者最多 3 条要点说明，避免长篇大论。
3. 多使用通俗易懂的表达，避免堆砌艰深术语。
4. 除非非常必要，不要重复题目原文。
5. 输出必须是 Markdown，但**不要使用任何标题**（禁止使用 #、##、###）。
6. 仅使用分行、普通列表和**粗体**组织内容；可使用数学公式（行内 $...$、块级 $$...$$）。

【学生背景与当前情况】
\(context)

【之前的对话（按时间顺序，若有）】
\(historyBlock)

【学生向张老师提出的最新问题】
\(userQuestion)

请以张老师的口吻，用简洁的方式给出针对性的学习建议与后续练习安排。
"""
    }
}

private struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

private struct ChatBubble: View {
    let message: ChatMessageRecord
    let isUser: Bool
    let attachments: [AttachmentChip]
    let onTapAttachment: ((AttachmentChip) -> Void)?

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            // 仅对用户消息展示图片/文件附件的大缩略图
            if isUser, !attachments.isEmpty {
                ForEach(attachments) { attachment in
                    Group {
                        switch attachment.kind {
                        case .image:
                            if let thumb = attachment.thumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFit()
                                    // 比输入区上方 80x80 的卡片更大一些
                                    .frame(maxWidth: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                // 历史会话恢复的图片附件（无缩略图）：使用占位图标
                                HStack(spacing: 8) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 18))
                                        .foregroundStyle(AppTheme.secondaryText)
                                    if !attachment.title.isEmpty {
                                        Text(attachment.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        case .pdf, .word:
                            HStack(spacing: 8) {
                                FileTypeBadge(kind: attachment.kind)
                                Text(attachment.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTapAttachment?(attachment)
                    }
                }
            }

            if isUser {
                // 学生提问：保持原来的纯文本蓝色气泡
                Text(message.text)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                // Agent / 张老师回答：使用支持 Markdown + LaTeX 的视图
                MarkdownReportView(content: message.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var bubbleBackground: Color {
        if isUser {
            return AppTheme.accentBlue
        } else {
            return Color(.systemGray6)
        }
    }

    private struct FileTypeBadge: View {
        let kind: AttachmentChip.Kind

        var body: some View {
            switch kind {
            case .pdf:
                Text("PDF")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .word:
                Text("WORD")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .image:
                EmptyView()
            }
        }
    }
}

/// 会话抽屉中的历史记录分组
private struct HistorySection: View {
    let title: String
    let sessions: [ChatSession]
    let onSelect: (ChatSession) -> Void
    let onDelete: (ChatSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            ForEach(sessions) { session in
                Button {
                    onSelect(session)
                } label: {
                    HStack {
                        Image(systemName: "message")
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(Self.dateFormatter.string(from: session.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .font(.subheadline)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                // 右滑显示删除图标（leading edge），符合「右扫」描述
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onDelete(session)
                    } label: {
                        Image("shanchu")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(.red)
                            .frame(width: 24, height: 24)
                    }
                }
                // 长按标题也提供删除入口
                .contextMenu {
                    Button(role: .destructive) {
                        onDelete(session)
                    } label: {
                        Label("删除会话", systemImage: "trash")
                    }
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}

// MARK: - 附件模型与卡片

struct AttachmentChip: Identifiable {
    enum Kind {
        case image
        case pdf
        case word
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var suggestions: [String]
    var thumbnail: UIImage?
    /// 对图片附件使用 VL 模型解析得到的 Markdown 内容
    var markdown: String? = nil
    /// 文件类附件对应的本地 URL（如果有）
    var fileURL: URL? = nil
    /// PDF 解析后的完整 Markdown 文件路径（analysis）
    var pdfAnalysisPath: String? = nil
    /// PDF 概要 Markdown 文件路径（summary）
    var pdfSummaryPath: String? = nil
    /// PDF 每页渲染得到的图片路径列表（用于后续 VL 问答）
    var pdfPageImagePaths: [String]? = nil

    static func image(title: String, suggestions: [String], thumbnail: UIImage?) -> AttachmentChip {
        AttachmentChip(kind: .image, title: title, suggestions: suggestions, thumbnail: thumbnail, markdown: nil, fileURL: nil)
    }

    static func pdf(title: String, suggestions: [String], fileURL: URL?) -> AttachmentChip {
        AttachmentChip(kind: .pdf, title: title, suggestions: suggestions, thumbnail: nil, markdown: nil, fileURL: fileURL)
    }

    static func word(title: String, suggestions: [String], fileURL: URL?) -> AttachmentChip {
        AttachmentChip(kind: .word, title: title, suggestions: suggestions, thumbnail: nil, markdown: nil, fileURL: fileURL)
    }
}

private struct AttachmentCard: View {
    let attachment: AttachmentChip
    let onRemove: () -> Void
    let onTap: (() -> Void)?

    init(
        attachment: AttachmentChip,
        onRemove: @escaping () -> Void,
        onTap: (() -> Void)? = nil
    ) {
        self.attachment = attachment
        self.onRemove = onRemove
        self.onTap = onTap
    }

    /// 输入框上方附件卡片的统一高度
    private let cardHeight: CGFloat = 72

    var body: some View {
        Group {
            switch attachment.kind {
            case .image:
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.systemGray6))
                            .frame(width: cardHeight, height: cardHeight)
                            .overlay {
                                if let thumb = attachment.thumbnail {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "photo")
                                        .font(.system(size: 24))
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                            .clipped()

                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color(.systemGray3))
                                .padding(4)
                        }
                    }
                }

            case .pdf, .word:
                HStack(spacing: 8) {
                    fileTypeBadge

                    Text(attachment.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(.systemGray3))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: cardHeight)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // 宽度根据内容自适应，但不超过高度的 2 倍
                .frame(maxWidth: cardHeight * 2, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }

    @ViewBuilder
    private var fileTypeBadge: some View {
        switch attachment.kind {
        case .pdf:
            Text("PDF")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .word:
            Text("WORD")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .image:
            EmptyView()
        }
    }
}

// MARK: - 轻量级 Agent 骨架

/// Agent 运行时上下文：包含当前问题、多轮对话与附件等信息
struct ChatAgentContext {
    var question: String
    var messages: [ChatMessageRecord]
    var attachments: [AttachmentChip]
    /// 工具可以往这里追加「中间结论」「环境说明」等备注，后续可拼进提示词
    var notes: [String] = []
    /// 某些工具可以直接给出最终回答（Markdown + 公式），若不为空则 Agent 不再调用文本大模型
    var directAnswerMarkdown: String? = nil
}

/// 一个可以被 Agent 调用的「工具」
protocol ChatAgentTool {
    /// 工具的唯一名称（可用于日志或后续扩展成可配置列表）
    var name: String { get }
    /// 人类可读的工具说明
    var description: String { get }
    /// 当前轮是否需要运行该工具
    func shouldRun(with context: ChatAgentContext) -> Bool
    /// 执行工具逻辑，可以原地修改上下文（例如追加 notes、补充附件解析结果等）
    func run(context: inout ChatAgentContext, settings: AppSettings, store: ScanStore) async
}

/// 一个极简的多工具 Agent：按顺序运行工具，然后调用大模型生成最终回答
final class ChatAgent {
    private let settings: AppSettings
    private unowned let store: ScanStore
    private let tools: [ChatAgentTool]

    init(settings: AppSettings, store: ScanStore, tools: [ChatAgentTool]) {
        self.settings = settings
        self.store = store
        self.tools = tools
    }

    /// 对外暴露的主入口：接收上下文，依次调用各个工具，最后调用 LLMService.chat 生成回答
    func answer(with initialContext: ChatAgentContext) async -> String {
        guard let cfg = settings.effectiveConfig() else {
            return "尚未配置可用的大模型服务。"
        }

        var context = initialContext

        // 1. 工具阶段：依次运行所有需要的工具，对上下文进行富化
        for tool in tools where tool.shouldRun(with: context) {
            await tool.run(context: &context, settings: settings, store: store)
        }

        // 如果有工具已经给出了直接回答（通常是 VL 模型结合图片），则优先返回该结果
        if let direct = context.directAnswerMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty {
            return direct
        }

        // 2. 构造一个基础提示词（仅为示例，可替换为你已有的 buildChatPrompt 逻辑）
        let historyBlock = context.messages
            .suffix(8)
            .map { msg -> String in
                let prefix = (msg.role == .user) ? "学生：" : "张老师："
                return prefix + msg.text
            }
            .joined(separator: "\n")

        var systemNotes = ""
        if !context.notes.isEmpty {
            systemNotes = "【Agent 中间结论与环境说明】\n" + context.notes.joined(separator: "\n") + "\n\n"
        }

        let prompt = """
你是一位耐心、专业的中学学科辅导老师「张老师」，需要用自然、鼓励式的中文为学生提供一对一学习建议。

\(systemNotes)【之前的对话（若有）】
\(historyBlock.isEmpty ? "（暂无）" : historyBlock)

【学生向张老师提出的最新问题】
\(context.question)

请以张老师的口吻，用简洁的方式给出针对性的学习建议与后续练习安排。
输出要求：
- 必须是 Markdown；
- 不要使用任何标题（禁止 #、##、###）；
- 仅用分行/列表和**粗体**组织内容；
- 支持并鼓励使用 LaTeX 数学公式（行内 $...$，块级 $$...$$）。
"""

        // 3. 调用底层大模型生成最终回答
        do {
            let reply = try await LLMService.chat(
                prompt: prompt,
                provider: settings.provider,
                config: cfg
            )
            return reply.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return error.localizedDescription
        }
    }
}

/// 工具示例：将附件（尤其是 PDF 概要）注入 Agent notes，供提示词使用
struct AttachmentSummaryTool: ChatAgentTool {
    let name: String = "attachment_summary"
    let description: String = "将当前问题相关的附件概要信息追加到 Agent notes 中，用于回答时参考。"

    func shouldRun(with context: ChatAgentContext) -> Bool {
        !context.attachments.isEmpty
    }

    func run(context: inout ChatAgentContext, settings: AppSettings, store: ScanStore) async {
        // 目前策略：优先使用附件中的 markdown 概要，其次是简单的文件名说明
        for att in context.attachments {
            switch att.kind {
            case .image:
                // 对图片：如果已有 markdown（来自 describeImage），则直接加入；否则仅记录有图片附件
                if let md = att.markdown, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    context.notes.append("【图片附件：\(att.title)】\n\(md)")
                } else {
                    context.notes.append("【图片附件】学生附带了一张图片：\(att.title)")
                }
            case .pdf, .word:
                if let md = att.markdown, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    context.notes.append("【文档附件概要：\(att.title)】\n\(md)")
                } else {
                    context.notes.append("【文档附件】学生附带了文档《\(att.title)》，可结合文档内容回答问题。")
                }
            }
        }
    }
}

/// 工具：当学生的问题明显在指向 PDF 文档中的具体题目时，在 PDF 渲染出的页面图片中查找并解析相关题目
struct PdfQuestionExtractionTool: ChatAgentTool {
    let name: String = "pdf_question_extraction"
    let description: String = "当学生提问中提到「这题」「图中」「图片里」等表述时，在 PDF 渲染出的页面图片中逐页查找并解析最相关的题目，支持 Markdown 与 LaTeX 公式。"

    func shouldRun(with context: ChatAgentContext) -> Bool {
        // 需要同时满足：有 PDF 附件且已生成页面图片 + 问题语句看起来在指向文档/题目
        let hasPdfPages = context.attachments.contains { $0.kind == .pdf && ($0.pdfPageImagePaths?.isEmpty == false) }
        let should = hasPdfPages && questionRefersToDocument(context.question)
        print("[camit][agent][pdfQ] shouldRun=\(should), hasPdfPages=\(hasPdfPages), question=\(context.question)")
        return should
    }

    func run(context: inout ChatAgentContext, settings: AppSettings, store: ScanStore) async {
        guard let cfg = settings.effectiveConfig() else { return }

        var usedAnyImage = false
        var foundAnswer: String? = nil

        // 仅针对 PDF：遍历该文档渲染出的每一页图片，依次尝试查找相关内容
        guard let pdfAtt = context.attachments.first(where: { $0.kind == .pdf && ($0.pdfPageImagePaths?.isEmpty == false) }),
              let paths = pdfAtt.pdfPageImagePaths else { return }
        print("[camit][agent][pdfQ] start run, total pages=\(paths.count)")

        for (idx, path) in paths.enumerated() {
            guard let img = UIImage(contentsOfFile: path),
                  let data = resizedJPEGData(from: img) else { continue }
            usedAnyImage = true
            print("[camit][agent][pdfQ] try page \(idx + 1) image \(path)")

            do {
                let answer = try await LLMService.answerQuestionAboutImage(
                    imageJPEGData: data,
                    question: context.question,
                    provider: settings.provider,
                    config: cfg
                )
                let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[camit][agent][pdfQ] page \(idx + 1) raw answer prefix=\(String(clean.prefix(80)))")
                if clean.uppercased() == "NOT_FOUND" || clean.isEmpty {
                    continue
                }
                foundAnswer = clean
                break
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                    // 工具调用超时：直接给出明确提示，不再继续尝试
                    context.directAnswerMarkdown = "抱歉，张老师在向这份文档查询题目时遇到**网络超时**，请检查网络后再试一次。"
                    return
                }
                // 其他错误：继续尝试后续页面，最终按「未发现」处理
                continue
            }
        }

        // 若找到答案，则直接作为本轮回答；若根本没找到相关内容，则给出「未发现」提示，不编造
        if let final = foundAnswer {
            context.directAnswerMarkdown = normalizePdfToolAnswer(final)
        } else if usedAnyImage {
            context.directAnswerMarkdown = """
**相关题目**
- 未发现与当前问题直接对应的题目内容

**解题说明**
抱歉，张老师在这份文档中没有找到和你问题**直接对应**的具体内容，请确认题目的页码或位置后再试一次（不会为你编造文档中不存在的内容）。
"""
        }
    }

    /// 粗略判断学生的问题是否在指向文档中的题目内容
    private func questionRefersToDocument(_ text: String) -> Bool {
        let t = text.lowercased()
        let hints = [
            "这题", "这道题", "第三题", "第3题", "第4题", "第5题",
            "第", "题目", "文档", "附件", "试卷", "pdf", "文件"
        ]
        if hints.contains(where: { text.contains($0) }) { return true }
        // 同时兼顾简单英文表达
        let englishHints = ["in the pdf", "in this file", "question in the document", "question 3"]
        return englishHints.contains(where: { t.contains($0) })
    }

    /// 缩小图片尺寸，降低 VL 请求体积，减少超时概率
    private func resizedJPEGData(from image: UIImage, maxSide: CGFloat = 1400) -> Data? {
        let size = image.size
        let maxCurrent = max(size.width, size.height)
        guard maxCurrent > 0 else { return nil }
        let scale = min(1.0, maxSide / maxCurrent)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.75)
    }

    /// 统一 PDF 工具的输出结构，确保气泡中按 Markdown + 公式稳定渲染
    private func normalizePdfToolAnswer(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // 已经是约定结构则直接返回
        if text.contains("**相关题目**") && text.contains("**解题思路与答案**") {
            return text
        }

        // 否则将原始内容包裹到标准 Markdown 结构中
        return """
**相关题目**
- （由文档页面识别）请参考下方解析中的题干与已知条件

**解题思路与答案**
\(text)
"""
    }
}

/// 工具：当学生的问题明显在指向 docx 文档中的具体题目时，先抽取文档文本再进行针对性作答
struct DocxQuestionExtractionTool: ChatAgentTool {
    let name: String = "docx_question_extraction"
    let description: String = "当学生提问指向 docx 附件中的某道题时，抽取文档文本并仅基于文档内容作答（找不到时返回 NOT_FOUND）。"

    func shouldRun(with context: ChatAgentContext) -> Bool {
        let hasDocx = context.attachments.contains {
            guard $0.kind == .word, let url = $0.fileURL else { return false }
            return url.pathExtension.lowercased() == "docx"
        }
        return hasDocx && questionRefersToDocument(context.question)
    }

    func run(context: inout ChatAgentContext, settings: AppSettings, store: ScanStore) async {
        guard let cfg = settings.effectiveConfig() else { return }
        guard let docxAtt = context.attachments.first(where: {
            guard $0.kind == .word, let url = $0.fileURL else { return false }
            return url.pathExtension.lowercased() == "docx"
        }), let fileURL = docxAtt.fileURL else { return }

        guard let text = extractDocxPlainText(from: fileURL),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // 限制输入体积，避免上下文过大导致失败
        let clipped = String(text.prefix(16000))
        let prompt = """
你是一位严谨的中学老师。你将收到一段从 docx 文档中抽取的文本以及学生问题。

规则：
1) 只能依据提供的 docx 文本回答，不得编造文档中不存在的内容。
2) 如果文档文本中找不到与问题直接对应的题目信息，只输出：NOT_FOUND
3) 如果找到了，请用中文 Markdown 输出，禁止使用标题（不能出现 #、##、###）；
4) 只用分行、列表和**粗体**组织内容，建议结构如下：
**相关题目**
- ...

**解题思路与答案**
...
（数学公式可用 LaTeX：$...$ 或 $$...$$）

【学生问题】
\(context.question)

【docx 文本（可能已截断）】
\(clipped)
"""

        do {
            let answer = try await LLMService.chat(
                prompt: prompt,
                provider: settings.provider,
                config: cfg
            )
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.uppercased() == "NOT_FOUND" || clean.isEmpty {
                context.directAnswerMarkdown = """
**相关题目**
- 未发现与当前问题直接对应的题目内容

**解题说明**
抱歉，张老师在这份 docx 文档中没有找到和你问题**直接对应**的具体内容，请补充题号或更明确的位置后再试一次（不会为你编造文档中不存在的内容）。
"""
                return
            }
            context.directAnswerMarkdown = normalizeDocxToolAnswer(clean)
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                context.directAnswerMarkdown = "抱歉，张老师在向这份 docx 文档查询题目时遇到**网络超时**，请检查网络后再试一次。"
                return
            }
        }
    }

    private func questionRefersToDocument(_ text: String) -> Bool {
        let t = text.lowercased()
        let hints = [
            "这题", "这道题", "第三题", "第3题", "第4题", "第5题",
            "第", "题目", "文档", "附件", "试卷", "docx", "文件"
        ]
        if hints.contains(where: { text.contains($0) }) { return true }
        let englishHints = ["in the docx", "in this file", "question in the document", "question 3"]
        return englishHints.contains(where: { t.contains($0) })
    }

    private func extractDocxPlainText(from url: URL) -> String? {
        guard let archive = try? Archive(url: url, accessMode: .read),
              let entry = archive["word/document.xml"] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else { return nil }

        // 先把段落边界替换成换行，避免整段黏连
        let paragraphMarked = xml.replacingOccurrences(of: "</w:p>", with: "\n")
        let pattern = "<w:t[^>]*>(.*?)</w:t>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(paragraphMarked.startIndex..., in: paragraphMarked)
        var pieces: [String] = []
        regex.enumerateMatches(in: paragraphMarked, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: paragraphMarked) else { return }
            let s = paragraphMarked[r]
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            pieces.append(String(s))
        }
        let joined = pieces.joined(separator: " ")
            .replacingOccurrences(of: " \n ", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func normalizeDocxToolAnswer(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        if text.contains("**相关题目**") && text.contains("**解题思路与答案**") {
            return text
        }
        return """
**相关题目**
- （由 docx 文本抽取）请参考下方解析中的题干与已知条件

**解题思路与答案**
\(text)
"""
    }
}

/// 工具：当学生的问题明显在指向图片附件中的具体题目时，直接在图片上用 VL 模型解析
struct ImageQuestionExtractionTool: ChatAgentTool {
    let name: String = "image_question_extraction"
    let description: String = "当学生提问中提到「这题」「图中」「图片里」等表述时，在图片附件上直接使用 VL 模型解析最相关的题目并作答（Markdown + LaTeX 公式）。"

    func shouldRun(with context: ChatAgentContext) -> Bool {
        let hasImage = context.attachments.contains { $0.kind == .image && $0.thumbnail != nil }
        return hasImage && questionRefersToImage(context.question)
    }

    func run(context: inout ChatAgentContext, settings: AppSettings, store: ScanStore) async {
        guard let cfg = settings.effectiveConfig() else { return }

        // 依次尝试所有图片附件，找到第一张能回答当前问题的
        let imageAttachments = context.attachments.filter { $0.kind == .image && $0.thumbnail != nil }
        guard !imageAttachments.isEmpty else { return }

        var usedAnyImage = false
        var foundAnswer: String? = nil

        for att in imageAttachments {
            guard let img = att.thumbnail,
                  let data = img.jpegData(compressionQuality: 0.8) else { continue }
            usedAnyImage = true

            do {
                let answer = try await LLMService.answerQuestionAboutImage(
                    imageJPEGData: data,
                    question: context.question,
                    provider: settings.provider,
                    config: cfg
                )
                let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.uppercased() == "NOT_FOUND" || clean.isEmpty {
                    continue
                }
                foundAnswer = clean
                break
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                    context.directAnswerMarkdown = "抱歉，张老师在解析这张图片时遇到**网络超时**，请检查网络后再试一次。"
                    return
                }
                continue
            }
        }

        if let final = foundAnswer {
            context.directAnswerMarkdown = final
        } else if usedAnyImage {
            context.directAnswerMarkdown = "抱歉，张老师在这张图片中没有找到和你问题**直接对应**的具体题目内容（不会为你编造图片中不存在的题目）。"
        }
    }

    /// 粗略判断学生的问题是否在指向图片中的内容
    private func questionRefersToImage(_ text: String) -> Bool {
        let t = text.lowercased()
        let hints = [
            "这题", "这道题", "这是什么图", "上面这题", "图中", "图片中", "图片里",
            "这张图", "上面的图", "这幅图"
        ]
        if hints.contains(where: { text.contains($0) }) { return true }
        let englishHints = ["in the picture", "in this picture", "in the image"]
        return englishHints.contains(where: { t.contains($0) })
    }
}
