import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import ScanCore

final class SimilarImagesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardSimilar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A photo-like scene: a gradient sky over gradient ground, a few objects and fine texture, so
    /// re-encoding or halving it keeps its structure the way a real photo does. (A flat drawing loses
    /// most of its features at half size: its variants measured 0.60 apart, real photos' rarely
    /// pass 0.45; see docs/plans/v0.4.md.) Variants differ in palette, shapes and layout.
    private func picture(_ variant: Int, width: Int = 800, height: Int = 600) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed = UInt64(variant + 1) &* 0x9E37_79B9_7F4A_7C15
        func random() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed >> 40) / CGFloat(1 << 24)
        }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
        let w = CGFloat(width), h = CGFloat(height), horizon = h * (variant == 0 ? 0.4 : 0.6)
        let palette: [CGColor] = variant == 0
            ? [color(0.3, 0.55, 0.95), color(0.9, 0.95, 1), color(0.2, 0.5, 0.15), color(0.45, 0.35, 0.2)]
            : [color(0.95, 0.5, 0.25), color(0.35, 0.2, 0.45), color(0.15, 0.2, 0.35), color(0.6, 0.6, 0.65)]
        let sky = CGGradient(colorsSpace: space, colors: [palette[0], palette[1]] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: horizon), options: [])
        let ground = CGGradient(colorsSpace: space, colors: [palette[2], palette[3]] as CFArray, locations: [0, 1])!
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: w, height: horizon))
        context.drawLinearGradient(ground, start: .zero, end: CGPoint(x: w, y: horizon), options: [])
        context.restoreGState()
        for _ in 0..<7 {
            context.setFillColor(color(random(), random(), random()))
            let box = CGRect(x: random() * w * 0.8, y: random() * h * 0.8, width: w * (0.08 + random() * 0.2), height: h * (0.08 + random() * 0.25))
            if variant == 0 { context.fillEllipse(in: box) } else { context.fill(box) }
        }
        for _ in 0..<6_000 {
            let shade = random()
            context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 0.3))
            context.fill(CGRect(x: random() * w, y: random() * h, width: 2, height: 2))
        }
        return context.makeImage()!
    }

    private func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @discardableResult
    private func save(_ image: CGImage, _ name: String, quality: CGFloat? = nil) -> URL {
        let url = root.appendingPathComponent(name)
        let type = quality == nil ? UTType.png.identifier : UTType.jpeg.identifier
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        let properties: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func tree() throws -> FileTree { try Scanner().scan(root: root.path) }

    func testFormatsAndResizeGroupButDifferentImageDoesNot() throws {
        let original = picture(0)
        save(original, "a.png")
        save(original, "b.jpg", quality: 0.6)
        save(resized(original, width: 400, height: 300), "c.png")
        save(picture(1), "different.png")
        let tree = try tree()
        do { _ = try SimilarImages.extract(root.appendingPathComponent("a.png").path, revision: SimilarOptions().revision) }
        catch { throw XCTSkip("Vision unavailable in this sandbox: \(error)") }
        let report = SimilarImages.find(in: tree.nodes, rootPath: tree.rootPath,
                                        options: SimilarOptions(minSize: 1, maxConcurrency: 4))
        let group = try XCTUnwrap(report.groups.first { $0.members.count >= 3 })
        XCTAssertEqual(Set(group.members.map { ($0.path as NSString).lastPathComponent }), ["a.png", "b.jpg", "c.png"])
        XCTAssertFalse(report.groups.flatMap(\.members).contains { $0.path.hasSuffix("different.png") })
        XCTAssertEqual(report.status, .complete)
        print("similar fixture revision=\(report.revision) threshold=\(SimilarOptions().threshold) img/s=\(report.imagesPerSecond)")
    }

    func testNotLocalNeverReachesExtractorAndHardlinksCountOnce() throws {
        save(picture(0), "a.png")
        try FileManager.default.linkItem(at: root.appendingPathComponent("a.png"),
                                         to: root.appendingPathComponent("alias.png"))
        save(picture(1), "cloud.png")
        let scanned = try tree()
        var nodes = scanned.nodes
        let cloud = try XCTUnwrap(scanned.child(named: "cloud.png", of: FileTree.root))
        nodes[Int(cloud)].rawAlloc = 0
        let lock = NSLock()
        var opened: [String] = []
        let report = SimilarImages.find(in: nodes, rootPath: root.path, options: SimilarOptions(minSize: 1),
                                        extract: { path, _ in
            lock.lock(); opened.append(path); lock.unlock()
            return SimilarFeature(vector: [1, 0, 0])
        })
        XCTAssertEqual(opened.count, 1)
        XCTAssertFalse(opened.contains { $0.hasSuffix("cloud.png") })
        XCTAssertEqual(report.candidateFiles, 1)
        XCTAssertEqual(report.skipped.map(\.reason), ["not_local"])
    }

    func testHardlinkGroupCannotClaimReclaimableBytes() throws {
        save(picture(0), "a.png")
        try FileManager.default.linkItem(at: root.appendingPathComponent("a.png"),
                                         to: root.appendingPathComponent("alias.png"))
        save(picture(0), "z.png")
        let scanned = try tree()
        let report = SimilarImages.find(in: scanned.nodes, rootPath: root.path,
                                        options: SimilarOptions(minSize: 1, threshold: 0.1),
                                        extract: { path, _ in
            let width = path.hasSuffix("z.png") ? 500 : 400
            return SimilarFeature(vector: [1, 0, 0], width: width, height: 300)
        })
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.reclaimableBytes, 0)
        XCTAssertEqual(group.members.first(where: { $0.node != group.suggestedKeep })?.sharedStorage, true)
    }

    func testFeatureCacheKeyIncludesRevision() throws {
        save(picture(0), "a.png")
        let scanned = try tree()
        let lock = NSLock()
        var calls = 0
        let extractor: (String, Int) throws -> SimilarFeature = { _, _ in
            lock.lock(); calls += 1; lock.unlock()
            return SimilarFeature(vector: [1, 0, 0])
        }
        let original = SimilarOptions(minSize: 1)
        let revised = SimilarOptions(minSize: 1, revision: original.revision + 1)
        _ = SimilarImages.find(in: scanned.nodes, rootPath: root.path, options: original,
                               extract: extractor, cacheEnabled: true)
        _ = SimilarImages.find(in: scanned.nodes, rootPath: root.path, options: original,
                               extract: extractor, cacheEnabled: true)
        _ = SimilarImages.find(in: scanned.nodes, rootPath: root.path, options: revised,
                               extract: extractor, cacheEnabled: true)
        XCTAssertEqual(calls, 2)
    }

    func testChangedIdentitySkipsBeforeExtractor() throws {
        save(picture(0), "a.png")
        let scanned = try tree()
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.png"),
                                         to: root.appendingPathComponent("old.png"))
        save(picture(1), "a.png")
        var opened = false
        let report = SimilarImages.find(in: scanned.nodes, rootPath: root.path,
                                        options: SimilarOptions(minSize: 1), extract: { _, _ in
            opened = true
            return SimilarFeature(vector: [1, 0, 0])
        })
        XCTAssertFalse(opened)
        XCTAssertEqual(report.skipped.first?.reason, "changed")
    }

    func testCandidateExtensionsScopeAndSymlink() throws {
        let extensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "dng", "cr2", "cr3", "nef", "arw"]
        for ext in extensions {
            try Data(repeating: 7, count: 1024).write(to: root.appendingPathComponent("image.\(ext)"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data(repeating: 8, count: 1024).write(to: root.appendingPathComponent("nested/inside.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"),
                                                   withDestinationURL: root.appendingPathComponent("image.png"))
        let scanned = try tree()
        let all = SimilarImages.candidates(in: scanned.nodes, rootPath: root.path, minSize: 1)
        XCTAssertEqual(all.paths.count, extensions.count + 1)
        XCTAssertFalse(all.paths.contains { $0.hasSuffix("link.png") })
        let nested = try XCTUnwrap(scanned.child(named: "nested", of: FileTree.root))
        XCTAssertEqual(SimilarImages.candidates(in: scanned.nodes, rootPath: root.path,
                                               under: nested, minSize: 1).paths,
                       [root.appendingPathComponent("nested/inside.png").path])
    }

    func testCancellationReturnsPartialGroups() throws {
        for index in 0..<4 { save(picture(index % 2), "\(index).png") }
        let scanned = try tree()
        let lock = NSLock()
        var extracted = 0
        let report = SimilarImages.find(in: scanned.nodes, rootPath: root.path,
                                        options: SimilarOptions(minSize: 1, threshold: 0.1, maxConcurrency: 1),
                                        isCancelled: { lock.lock(); defer { lock.unlock() }; return extracted >= 2 },
                                        extract: { _, _ in
            lock.lock(); extracted += 1; lock.unlock()
            return SimilarFeature(vector: [1, 0, 0])
        })
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(report.pendingFiles, 2)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertTrue(report.groups[0].partial)
    }

    func testDistanceOrderingMatchesVision() throws {
        let urls = [save(picture(0), "a.png"), save(picture(0), "b.jpg", quality: 0.6),
                    save(resized(picture(0), width: 400, height: 300), "c.png"), save(picture(1), "d.png")]
        var observations: [VNFeaturePrintObservation] = []
        var vectors: [[Float]] = []
        for url in urls {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = SimilarOptions().revision
            do { try VNImageRequestHandler(url: url).perform([request]) }
            catch { throw XCTSkip("Vision unavailable in this sandbox: \(error)") }
            let observation = try XCTUnwrap(request.results?.first)
            observations.append(observation)
            vectors.append(observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
        }
        var pairs: [(vision: Float, accelerated: Float)] = []
        for i in 0..<urls.count {
            for j in (i + 1)..<urls.count {
                var distance: Float = 0
                try observations[i].computeDistance(&distance, to: observations[j])
                pairs.append((distance, SimilarImages.distance(vectors[i], vectors[j])))
            }
        }
        let visionOrder = pairs.indices.sorted { pairs[$0].vision < pairs[$1].vision }
        let acceleratedOrder = pairs.indices.sorted { pairs[$0].accelerated < pairs[$1].accelerated }
        XCTAssertEqual(visionOrder, acceleratedOrder)
        let threshold = SimilarOptions().threshold
        for (index, pair) in pairs.enumerated() {
            let i = index < 3 ? 0 : (index < 5 ? 1 : 2)
            let j = [1, 2, 3, 2, 3, 3][index]
            XCTAssertEqual(SimilarImages.groups([vectors[i], vectors[j]], threshold: threshold).contains { $0.count == 2 },
                           pair.vision <= threshold)
        }
        let same = [pairs[0].vision, pairs[1].vision, pairs[3].vision].max()!
        let different = [pairs[2].vision, pairs[4].vision, pairs[5].vision].min()!
        XCTAssertLessThan(same, threshold)
        XCTAssertLessThan(threshold, different)
        print(String(format: "similar threshold calibration: max same %.3f < %.3f < min different %.3f", same, threshold, different))
        print("similar calibrated distances: \(pairs.map { String(format: "%.3f/%.3f", $0.vision, $0.accelerated) }.joined(separator: ", "))")
    }

    /// Files inside a Photos library or an app belong to it, and the Trash is already being emptied:
    /// none of them may become a candidate the app would offer to trash.
    func testPackagesAndTrashAreNeverCandidates() throws {
        let image = picture(0, width: 64, height: 48)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos Library.photoslibrary/originals/A"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tool.app/Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        save(image, "Photos Library.photoslibrary/originals/A/IMG_1.png")
        save(image, "Tool.app/Contents/Resources/icon.png")
        save(image, ".Trash/old.png")
        for dir in ["Catalog Previews.lrdata/1", "Plug.framework/Resources", "repo/.git/objects"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
            save(image, dir + "/p.png")
        }
        save(image, "kept.png")
        let scanned = try tree()
        let found = SimilarImages.candidates(in: scanned.nodes, rootPath: root.path, minSize: 1)
        XCTAssertEqual(found.paths.map { ($0 as NSString).lastPathComponent }, ["kept.png"])
        // Zoomed into a package, there is nothing to offer either.
        let previews = try XCTUnwrap(scanned.child(named: "Catalog Previews.lrdata", of: FileTree.root))
        XCTAssertEqual(SimilarImages.candidates(in: scanned.nodes, rootPath: root.path, under: previews, minSize: 1).paths, [])
        XCTAssertEqual(Packages.enclosing("/a/Plug.framework/Resources/p.png"), "Plug.framework")
        XCTAssertNil(Packages.enclosing("/a/Plug.framework"))
    }

    /// Without the no-download policy a worker must read nothing: every file is reported, none opened.
    func testNoFileIsReadWhenDownloadsCannotBeTurnedOff() throws {
        for name in ["a.png", "b.png", "c.png"] { save(picture(0, width: 64, height: 48), name) }
        let scanned = try tree()
        let lock = NSLock()
        var opened = 0
        let report = SimilarImages.find(in: scanned.nodes, rootPath: root.path, options: SimilarOptions(minSize: 1),
                                        extract: { _, _ in lock.lock(); opened += 1; lock.unlock(); return SimilarFeature(vector: [1, 0, 0]) },
                                        materializationOff: { nil })
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.skipped.map(\.reason), ["not_local", "not_local", "not_local"])
        XCTAssertEqual(report.groups.count, 0)
    }

    /// Batched leader grouping gives exactly what one leader at a time over all pairs gives, across
    /// batch boundaries, and stops between batches when cancelled.
    func testLeaderGroupsMatchAReferenceAndCancelBetweenBatches() {
        var seed: UInt64 = 42
        func random() -> Float { seed = seed &* 6_364_136_223_846_793_005 &+ 1; return Float(seed >> 40) / Float(1 << 24) - 0.5 }
        let centres = (0..<12).map { _ in (0..<16).map { _ in random() * 4 } }
        let vectors = (0..<400).map { i in centres[i % centres.count].map { $0 + random() * 0.3 } }
        let order = Array((0..<400).reversed())
        func reference(_ threshold: Float) -> [[Int]] {
            var grouped = [Bool](repeating: false, count: vectors.count), out: [[Int]] = []
            for leader in order where !grouped[leader] {
                grouped[leader] = true
                var group = [leader]
                for j in vectors.indices where !grouped[j] && SimilarImages.distance(vectors[leader], vectors[j]) <= threshold {
                    grouped[j] = true; group.append(j)
                }
                if group.count > 1 { out.append(group) }
            }
            return out
        }
        for threshold: Float in [0.3, 0.6, 1.2] {
            XCTAssertEqual(SimilarImages.leaderGroups(vectors, threshold: threshold, order: order).groups, reference(threshold), "\(threshold)")
        }
        var calls = 0
        let cut = SimilarImages.leaderGroups(vectors, threshold: 0.01, order: order, isCancelled: { calls += 1; return calls > 1 })
        XCTAssertTrue(cut.cancelled)
    }

    /// The app cancels through Swift task cancellation: `Task.isCancelled` only answers on the task's
    /// own thread, not on the worker threads that extract, so the caller's thread must ask.
    func testTaskCancellationStopsExtraction() async throws {
        for index in 0..<40 { save(picture(0, width: 64, height: 48), String(format: "%02d.png", index)) }
        let scanned = try tree()
        let nodes = scanned.nodes, rootPath = root.path
        let worker = Task.detached { () -> SimilarReport in
            SimilarImages.find(in: nodes, rootPath: rootPath, options: SimilarOptions(minSize: 1, maxConcurrency: 2),
                               isCancelled: { Task<Never, Never>.isCancelled },
                               extract: { _, _ in
                Thread.sleep(forTimeInterval: 0.05)
                return SimilarFeature(vector: [1, 0, 0])
            })
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        worker.cancel()
        let report = await worker.value
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertLessThan(report.processedFiles, 30, "extraction kept going after the task was cancelled")
    }

    /// A chain A~B~C where A and C are far apart (frames of a slow pan) must not become one group:
    /// every member has to be similar to the image the group suggests keeping.
    func testChainDoesNotGroupImagesThatAreFarApart() throws {
        // Unit vectors at 0°, 20°, 40°: neighbours are 0.347 apart, the ends 0.684.
        func at(_ degrees: Float) -> [Float] { [cos(degrees * .pi / 180), sin(degrees * .pi / 180), 0] }
        let vectors = [at(0), at(20), at(40)]
        let groups = SimilarImages.groups(vectors, threshold: 0.45, order: [1, 0, 2])
        XCTAssertEqual(groups.map { Set($0) }, [[1, 0, 2]].map(Set.init), "B leads and both ends are within reach of B")
        let fromEnd = SimilarImages.groups(vectors, threshold: 0.45, order: [0, 1, 2])
        XCTAssertEqual(fromEnd, [[0, 1]], "A leads; C is only reachable through B")
        XCTAssertTrue(SimilarImages.groups(vectors, threshold: 0.45, order: [0, 1, 2]).allSatisfy { g in
            g.allSatisfy { SimilarImages.distance(vectors[g[0]], vectors[$0]) <= 0.45 }
        })

        save(picture(0), "a.png"); save(picture(0), "b.png"); save(picture(0), "c.png")
        let scanned = try tree()
        let report = SimilarImages.find(in: scanned.nodes, rootPath: root.path, options: SimilarOptions(minSize: 1),
                                        extract: { path, _ in
            switch (path as NSString).lastPathComponent {
            case "a.png": return SimilarFeature(vector: at(0), width: 100, height: 100)
            case "b.png": return SimilarFeature(vector: at(20), width: 50, height: 50)
            default: return SimilarFeature(vector: at(40), width: 10, height: 10)
            }
        })
        XCTAssertEqual(report.groups.count, 1)
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(Set(group.members.map { ($0.path as NSString).lastPathComponent }), ["a.png", "b.png"])
        XCTAssertEqual(group.suggestedKeep, try XCTUnwrap(scanned.child(named: "a.png", of: FileTree.root)))
    }

    func testTwoHundredImageThroughput() throws {
        let image = picture(0, width: 128, height: 96)
        for index in 0..<200 { save(image, String(format: "%03d.png", index)) }
        let scanned = try tree()
        let report = SimilarImages.find(in: scanned.nodes, rootPath: root.path,
                                        options: SimilarOptions(minSize: 1, maxConcurrency: 8),
                                        extract: { path, _ in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NSError(domain: "SimilarTest", code: 1)
            }
            return SimilarFeature(vector: [Float(image.width), Float(image.height), 1],
                                  width: image.width, height: image.height)
        })
        XCTAssertEqual(report.processedFiles, 200)
        XCTAssertGreaterThan(report.imagesPerSecond, 0)
        print(String(format: "similar throughput (ImageIO extractor, not Vision): %.1f img/s (200 generated images, revision %d)",
                     report.imagesPerSecond, report.revision))
    }

    func testInjectedFeaturesGroupAndPreferLargestPixels() throws {
        let original = picture(0)
        save(original, "a.png")
        save(original, "b.jpg", quality: 0.6)
        save(resized(original, width: 400, height: 300), "c.png")
        save(picture(1), "different.png")
        let scanned = try tree()
        let report = SimilarImages.find(in: scanned.nodes, rootPath: root.path,
                                        options: SimilarOptions(minSize: 1, threshold: 0.1),
                                        extract: { path, _ in
            let name = (path as NSString).lastPathComponent
            return name == "different.png" ? SimilarFeature(vector: [0, 1, 0]) :
                SimilarFeature(vector: [1, 0, 0], width: name == "c.png" ? 200 : 400,
                               height: name == "c.png" ? 150 : 300)
        })
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(group.members.count, 3)
        XCTAssertFalse(group.members.contains { $0.path.hasSuffix("different.png") })
        XCTAssertNotEqual(group.suggestedKeep, try XCTUnwrap(scanned.child(named: "c.png", of: FileTree.root)))
    }
}
