import Foundation
import UIKit
@preconcurrency import Combine

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var items: [ScanItem] = []

    private let fileName = "scans.json"

    init() {
        load()
        if items.isEmpty {
            seed()
        }
    }

    /// Analyze the captured image with VL model; if it's a paper/homework, persist it and extracted questions.
    func analyzeAndAddScan(image: UIImage, config: BailianConfig) async throws -> ScanItem? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let result = try await BailianClient().analyzePaper(imageJPEGData: data, config: config)

        guard result.is_homework_or_exam else {
            return nil
        }

        let now = Date()
        let imageFileName = "scan-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: imageFileName) {
            try? data.write(to: url, options: [.atomic])
        }

        let subject = Subject(rawValue: result.subject) ?? .other
        let grade = Grade(rawValue: result.grade) ?? .other

        let questions: [PaperQuestion] = result.normalizedItems.enumerated().map { idx, item in
            let cropFileName = cropQuestionImage(from: image, bbox: item.bbox, index: idx)
            return PaperQuestion(
                index: idx + 1,
                kind: item.type,
                text: item.content,
                isWrong: false,
                cropImageFileName: cropFileName
            )
        }

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "试卷/作业 \(DateFormatter.shortDate.string(from: now))"
            : result.title

        let item = ScanItem(
            title: title,
            createdAt: now,
            grade: grade,
            subject: subject,
            imageFileNames: [imageFileName],
            questions: questions,
            isHomeworkOrExam: true,
            isArchived: false,
            score: result.score
        )

        items.insert(item, at: 0)
        save()
        return item
    }

    func toggleWrong(scanID: UUID, questionID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        guard let q = items[i].questions.firstIndex(where: { $0.id == questionID }) else { return }
        items[i].questions[q].isWrong.toggle()
        save()
    }

    func archive(scanID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        items[i].isArchived = true
        save()
    }

    func delete(scanID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        for name in items[i].imageFileNames {
            if let url = try? imageURL(fileName: name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        items.remove(at: i)
        save()
    }

    /// Add another image to an existing paper; run VL analysis and merge extracted questions.
    func addImage(scanID: UUID, image: UIImage, config: BailianConfig) async throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }

        let fileName = "scan-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: fileName) {
            try? data.write(to: url, options: [.atomic])
        }
        items[i].imageFileNames.append(fileName)

        let result = try await BailianClient().analyzePaper(imageJPEGData: data, config: config)
        let startIndex = items[i].questions.count
        let newQuestions: [PaperQuestion] = result.normalizedItems.enumerated().map { idx, item in
            let cropFileName = cropQuestionImage(from: image, bbox: item.bbox, index: startIndex + idx)
            return PaperQuestion(
                index: startIndex + idx + 1,
                kind: item.type,
                text: item.content,
                isWrong: false,
                cropImageFileName: cropFileName
            )
        }
        items[i].questions.append(contentsOf: newQuestions)
        save()
    }

    func updateMeta(
        scanID: UUID,
        title: String,
        grade: Grade,
        subject: Subject,
        score: Int?
    ) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        items[i].title = title
        items[i].grade = grade
        items[i].subject = subject
        items[i].score = score
        save()
    }

    func updateQuestionAnalysis(
        scanID: UUID,
        questionID: UUID,
        section: String?,
        answer: String,
        explanation: String
    ) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        guard let q = items[i].questions.firstIndex(where: { $0.id == questionID }) else { return }
        items[i].questions[q].section = section
        items[i].questions[q].answer = answer
        items[i].questions[q].explanation = explanation
        save()
    }

    func save() {
        do {
            let url = try dataURL()
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic])
        } catch {
            // best-effort
        }
    }

    func load() {
        do {
            let url = try dataURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([ScanItem].self, from: data)
        } catch {
            // best-effort
        }
    }

    func imageURL(for item: ScanItem, index: Int = 0) -> URL? {
        guard index >= 0, index < item.imageFileNames.count else { return nil }
        let name = item.imageFileNames[index]
        return try? imageURL(fileName: name)
    }

    /// 根据文件名获取图片 URL（用于切图等）
    func imageURL(fileName: String) throws -> URL {
        let dir = try scansDir()
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    /// 根据 bbox 从图片中切出题目横条（宽度=试卷宽度，高度=题目高度上下各扩充50%），返回保存的文件名；若无 bbox 则返回 nil
    private func cropQuestionImage(from image: UIImage, bbox: BBox?, index: Int) -> String? {
        guard let bbox = bbox else { return nil }
        
        // 先校正图片方向，确保 cgImage 的宽高和显示方向一致
        let normalizedImage = normalizeImageOrientation(image)
        guard let cgImage = normalizedImage.cgImage else { return nil }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // 归一化坐标转像素坐标
        let bboxY = CGFloat(bbox.y) * imageHeight
        let bboxHeight = CGFloat(bbox.height) * imageHeight

        // 宽度：整个试卷宽度（不裁剪左右）
        let x: CGFloat = 0
        let width = imageWidth

        // 高度：题目高度上下各扩充 50%
        let expandHeight = bboxHeight * 0.5
        let y = max(0, bboxY - expandHeight)
        var height = bboxHeight + expandHeight * 2
        
        // 确保不超出图片边界
        if y + height > imageHeight {
            height = imageHeight - y
        }

        let cropRect = CGRect(x: x, y: y, width: width, height: height)
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return nil }
        let croppedImage = UIImage(cgImage: croppedCGImage)

        guard let data = croppedImage.jpegData(compressionQuality: 0.85) else { return nil }
        let fileName = "crop-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: fileName) {
            try? data.write(to: url, options: [.atomic])
        }
        return fileName
    }
    
    /// 校正图片方向，返回正向的图片
    private func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return normalizedImage ?? image
    }

    private func dataURL() throws -> URL {
        let dir = try appSupportDir()
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    private func appSupportDir() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("camit", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func scansDir() throws -> URL {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("camit_scans", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func seed() {
        let now = Date()
        items = [
            ScanItem(title: "数学单元测验", createdAt: now, grade: .primary5, subject: .math, imageFileNames: [], questions: []),
            ScanItem(title: "英语阅读测试", createdAt: now.addingTimeInterval(-2 * 3600), grade: .primary6, subject: .english, imageFileNames: [], questions: []),
            ScanItem(title: "物理期中试卷", createdAt: now.addingTimeInterval(-8 * 24 * 3600), grade: .junior2, subject: .physics, imageFileNames: [], questions: []),
            ScanItem(title: "化学习题作业", createdAt: now.addingTimeInterval(-9 * 24 * 3600), grade: .junior3, subject: .chemistry, imageFileNames: [], questions: []),
        ]
        save()
    }
}

private enum DateFormatter {
    static let shortDate: Foundation.DateFormatter = {
        let f = Foundation.DateFormatter()
        f.locale = .current
        f.dateFormat = "M/d"
        return f
    }()
}

