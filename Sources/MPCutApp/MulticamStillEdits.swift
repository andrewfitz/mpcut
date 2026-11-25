import AppKit
import MPCutCore

@MainActor
extension MulticamEditorModel {
    var canReplaceMulticamPicture: Bool { project != nil && !isBusy && markedGroupSpan != nil }

    @discardableResult
    func performStillEdit(_ action: String, _ change: (CutProject) throws -> CutProject) -> Bool {
        guard !isBusy, let project else { return false }
        do {
            let document = try change(.multicam(project))
            guard case .multicam(let updated) = try colorPolicyForStillEdit(document) else { return false }
            preview.pause()
            return edit(action) { $0 = updated }
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func colorPolicyForStillEdit(_ document: CutProject) throws -> CutProject {
        guard document.programColorPolicy == nil, case .multicam(let snapshot) = document,
              !snapshot.stillReplacements.isEmpty || !document.stillInserts.isEmpty else { return document }
        let retained = try snapshot.plan().picture.lazy.compactMap { self.media[$0.source]?.videoStream }.first
        let reference = retained ?? snapshot.pictureSources.lazy.compactMap { self.media[$0.id]?.videoStream }.first
        guard let reference, let policy = try? StillProgramColorPolicy.resolving(source: reference) else { return document }
        return try document.settingStillColorPolicy(policy)
    }

    private func stillPresentationBoundary(_ time: RationalTime) -> RationalTime {
        guard let project, time != project.range.from, time != project.range.to else { return time }
        guard let selection = project.selection(at: time), selection.at != time else { return time }
        guard let source = project.pictureSource(for: selection.angle, at: time),
              let frames = media[source.id]?.frames, !frames.isEmpty,
              let localTime = try? time.subtracting(source.offset) else {
            return snappedFrame(time, delta: 0) ?? time
        }
        let index = frames.lowerBound { $0.time > localTime }
        guard index > 0, let boundary = try? frames[index - 1].time.adding(source.offset) else { return time }
        return max(selection.at, boundary)
    }

    func stillReplacementBounds(_ span: AudioSpan) -> MulticamRange {
        func boundary(_ time: RationalTime) -> RationalTime {
            guard time != project?.range.from, time != project?.range.to else { return time }
            return stillPresentationBoundary(snappedAnalysisTime(time) ?? time)
        }
        return .init(from: boundary(span.from), to: boundary(span.to))
    }

    func multicamStillCadence(atGroup time: RationalTime) -> RationalTime? {
        guard let project, let id = project.selection(at: time)?.angle ?? project.switches.last?.angle,
              let source = project.pictureSource(for: id, at: time, exclusiveEnd: time == project.range.to) else { return nil }
        return multicamStillCadence(angle: source.id)
    }

    private func multicamStillCadence(angle id: String) -> RationalTime? {
        guard let info = media[id], info.hasFullEditIndex, let rate = info.videoStream?.frameRate, rate > .zero else {
            return nil
        }
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        guard !info.frames.isEmpty, info.frames.allSatisfy({ $0.duration == cadence }) else { return nil }
        return cadence
    }

    func stillFrameBoundary(_ time: RationalTime, cadence: RationalTime, nearest: Bool = false) -> RationalTime? {
        guard cadence > .zero,
              let count = try? time.multiplied(by: .init(numerator: cadence.denominator, denominator: cadence.numerator)) else {
            return nil
        }
        let whole = count.numerator / count.denominator
        let fraction = count.numerator % count.denominator
        let half = count.denominator / 2 + count.denominator % 2
        let frames = nearest && fraction >= half ? whole + 1 : whole
        return try? cadence.multiplied(by: .init(numerator: frames))
    }

    func trimAssemblyStill(_ index: Int, edge: TimelineEdge, localTime: RationalTime, commit: Bool) -> RationalTime? {
        guard !isBusy, let still = assemblyStill(at: index),
              let frame = stillFrameBoundary(max(.zero, localTime), cadence: still.cadence, nearest: true),
              let duration = edge == .start ? try? still.duration.subtracting(frame) : frame,
              duration > .zero else { return nil }
        if commit && duration != still.duration {
            guard performStillEdit("Trim Still", { try $0.resizingStill(id: still.id, duration: duration, cadence: still.cadence) }) else {
                return nil
            }
            selectAssemblyOccurrence(index)
        }
        return frame
    }

    func chooseReplaceMulticamPicture() {
        guard canReplaceMulticamPicture, let span = markedGroupSpan else { return }
        let bounds = stillReplacementBounds(span)
        let revision = mcpRevision
        StillPanels.chooseImage(in: window) { [weak self] url in
            guard let self, self.mcpRevision == revision else { return }
            self.replaceMulticamPicture(with: url, bounds: bounds)
        }
    }

    func replaceMulticamPicture(with url: URL) {
        guard let span = markedGroupSpan else { return }
        replaceMulticamPicture(with: url, bounds: stillReplacementBounds(span))
    }

    private func replaceMulticamPicture(with url: URL, bounds: MulticamRange) {
        inspectMulticamImages([url]) { [weak self] assets in
            let asset = assets[0]
            self?.performStillEditByHand("Replace Picture") { document in
                try document.addingStillAsset(asset).addingStillReplacement(
                    .init(id: ProjectIdentifier.make(), assetID: asset.id, framing: .fit, coverage: .group(bounds))
                )
            }
        }
    }

    func dropMulticamMedia(_ urls: [URL], atGroup group: RationalTime? = nil,
                           atAssembly assembly: RationalTime? = nil) {
        if !urls.isEmpty, urls.allSatisfy(StillPanels.isSupportedImage) {
            dropMulticamStills(urls, atGroup: group, atAssembly: assembly,
                               replacingMarkedRange: NSEvent.modifierFlags.contains(.option))
        } else {
            importSources(urls)
        }
    }

    func dropMulticamStills(_ urls: [URL], atGroup group: RationalTime? = nil,
                            atAssembly assembly: RationalTime? = nil, replacingMarkedRange: Bool) {
        guard !isBusy, project != nil, !urls.isEmpty else { return }
        if replacingMarkedRange {
            guard urls.count == 1, let url = urls.first, canReplaceMulticamPicture else {
                fail("Mark a picture range and drop one image to replace it.")
                return
            }
            replaceMulticamPicture(with: url)
        } else if let group {
            guard let position = assemblyPosition(for: group) else {
                fail("This group position is outside the assembled ranges. Drop the still on the assembly timeline.")
                return
            }
            insertMulticamStills(urls, atAssembly: position)
        } else {
            insertMulticamStills(urls, atAssembly: assembly)
        }
    }

    var canSpaceClips: Bool { !isBusy && project.map { CutProject.multicam($0).hasSpacingBoundaries } == true }

    func chooseSpaceClips() {
        guard canSpaceClips else { return }
        preview.pause()
        let revision = mcpRevision
        StillPanels.spaceClips(cadence: multicamStillCadence(atAssembly: .zero), seconds: preferences.gapDuration,
                               color: preferences.gapColor, in: window) { [weak self] timing, cadence, background in
            guard let self, self.mcpRevision == revision, self.canSpaceClips else { return }
            self.performStillEditByHand("Space Clips") { document in
                try timing.applying(to: document, cadence: cadence, background: background,
                                    relativeTo: self.projectURL ?? self.draft.url)
            }
        }
    }

    func chooseInsertGap() {
        guard !isBusy, project != nil else { return }
        preview.pause()
        guard let requested = stillInsertionPlayhead() else { return }
        let position = snappedAssemblyStillPosition(requested)
        let revision = mcpRevision
        StillPanels.gap(cadence: multicamStillCadence(atAssembly: position), seconds: preferences.gapDuration,
                        color: preferences.gapColor, in: window) { [weak self] duration, cadence, framing in
            guard let self, self.mcpRevision == revision, !self.isBusy else { return }
            let id = ProjectIdentifier.make()
            if self.performStillEditByHand("Insert Color Gap", { document in
                let asset = document.stillAssets.first(where: \.isGap) ?? StillAsset(gapID: ProjectIdentifier.make(avoiding: document.stillAssets.map(\.id)))
                let gap = StillInsert(id: id, assetID: asset.id, duration: duration, cadence: cadence, framing: framing)
                return try document.addingStillAsset(asset).insertingStill(gap, at: position)
            }), let index = self.assemblyItems.firstIndex(where: { $0.still?.id == id }) {
                self.selectAssemblyOccurrence(index)
            }
        }
    }

    func chooseInsertMulticamStill() {
        guard !isBusy, project != nil else { return }
        preview.pause()
        guard let position = stillInsertionPlayhead() else { return }
        let revision = mcpRevision
        StillPanels.chooseImage(in: window) { [weak self] url in
            guard let self, self.mcpRevision == revision else { return }
            self.insertMulticamStill(url, atAssembly: position)
        }
    }

    func insertMulticamStill(_ url: URL, atAssembly explicitTime: RationalTime? = nil) {
        insertMulticamStills([url], atAssembly: explicitTime)
    }

    private func stillInsertionPlayhead() -> RationalTime? {
        if assemblyPreview { return preview.currentTime() }
        if let position = assemblyPosition(for: currentGroupTime()) { return position }
        fail("The group playhead is outside the assembled ranges. Choose an insertion point in the assembly.")
        return nil
    }

    func assemblyStillDropTime(_ seconds: Double) -> RationalTime? {
        let index = assemblyRangeEnds.lowerBound { $0.seconds >= seconds }
        if assemblyRangeEnds.indices.contains(index), assemblyRangeEnds[index].seconds == seconds {
            return assemblyRangeEnds[index]
        }
        return timelineRationalTime(seconds)
    }

    func insertMulticamStills(_ urls: [URL], atAssembly explicitTime: RationalTime? = nil) {
        guard !urls.isEmpty, !isBusy, project != nil else { return }
        preview.pause()
        guard let requested = explicitTime ?? stillInsertionPlayhead() else { return }
        let position = snappedAssemblyStillPosition(requested)
        // The Settings duration, rounded to a whole frame at the cadence there (30 fps when it has none).
        let (duration, cadence) = defaultStillTiming(cadence: multicamStillCadence(atAssembly: position))
        let revision = mcpRevision
        let title = urls.count == 1 ? "Insert Still" : "Insert \(urls.count) Stills"
        StillPanels.duration(title: "\(title) at Assembly Time \(position)", duration: duration,
                             cadence: cadence, in: window) { [weak self] duration, cadence in
            guard let self, self.mcpRevision == revision else { return }
            self.inspectMulticamImages(urls) { [weak self] assets in
                guard let self else { return }
                let firstID = ProjectIdentifier.make()
                if self.performStillEditByHand(title, { project in
                    var document = project
                    var at = position
                    for (index, asset) in assets.enumerated() {
                        let id = index == 0 ? firstID : ProjectIdentifier.make()
                        document = try document.addingStillAsset(asset)
                        document = try document.insertingStill(.init(id: id, assetID: asset.id, duration: duration,
                                                                     cadence: cadence), at: at)
                        at = try at.adding(duration)
                    }
                    return document
                }), let index = self.assemblyItems.firstIndex(where: { $0.still?.id == firstID }) {
                    self.preferences.recentFiles.record(urls)
                    self.selectAssemblyOccurrence(index)
                }
            }
        }
    }

    func multicamStillCadence(atAssembly position: RationalTime) -> RationalTime? {
        guard !assemblyItems.isEmpty else { return nil }
        let index = min(assemblyItems.count - 1, assemblyRangeEnds.lowerBound { $0 > position })
        if let still = assemblyStill(at: index) { return still.cadence }
        guard let range = assemblyRange(at: index),
              let time = try? range.from.adding(position.subtracting(assemblyStart(at: index))) else { return nil }
        // At the final assembly boundary, use the rate of the range that just ended.
        if time >= range.to,
           let angle = project?.switches.last(where: { $0.at < range.to })?.angle {
            return multicamStillCadence(angle: angle)
        }
        return multicamStillCadence(atGroup: max(range.from, time))
    }

    func snappedAssemblyStillPosition(_ requested: RationalTime) -> RationalTime {
        guard let end = assemblyRangeEnds.last, .zero < requested, requested < end else { return requested }
        let index = assemblyRangeEnds.lowerBound { $0 > requested }
        let start = assemblyStart(at: index)
        if requested == start { return start }
        guard let range = assemblyRange(at: index),
              let group = try? range.from.adding(requested.subtracting(start)) else { return requested }
        let candidate = snappedAnalysisTime(group, within: range, includeEnd: true) ?? group
        let snapped = stillPresentationBoundary(candidate)
        return (try? start.adding(min(range.to, max(range.from, snapped)).subtracting(range.from))) ?? requested
    }

    func assemblyPosition(for group: RationalTime) -> RationalTime? {
        let selectedRange = assemblyRange(at: selectedOccurrence)
        let index = selectedRange?.contains(group) == true || selectedRange?.to == group ? selectedOccurrence
            : assemblyGroupIndices.first { assemblyRange(at: $0)?.contains(group) == true }
                ?? assemblyGroupIndices.last { assemblyRange(at: $0)?.to == group }
        guard let index, let range = assemblyRange(at: index),
              let offset = try? group.subtracting(range.from),
              let output = try? assemblyStart(at: index).adding(offset) else {
            return nil
        }
        return output
    }

    private func inspectMulticamImages(_ urls: [URL], reuseAssets: Bool = true,
                                       completion: @escaping ([StillAsset]) -> Void) {
        guard !isBusy, let project else { return }
        let existing = reuseAssets ? project.stillAssets : []
        let revision = mcpRevision
        let generation = mcpGeneration
        preview.pause()
        run("Reading still images…", kind: "still_import") { token, _ in
            try StillPanels.assets(for: urls, existing: existing, cancelled: { token.isCancelled })
        } onSuccess: { [weak self] assets in
            guard let self, self.mcpGeneration == generation else { return }
            guard self.mcpRevision == revision else {
                self.fail("The project changed while reading the images.")
                return
            }
            completion(assets)
        }
    }
}

@MainActor
extension MulticamEditorModel {
    var multicamStillRows: [StillPlacementRow] {
        guard let project else { return [] }
        let assets = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0) })
        let inserts = assemblyItems.enumerated().compactMap { index, item -> StillPlacementRow? in
            guard let insert = item.still, let asset = assets[insert.assetID] else { return nil }
            return StillPlacementRow(id: insert.id, title: asset.displayName, details:
                "Insert · Assembly \(assemblyStart(at: index))–\(assemblyRangeEnds[index]) · \(insert.duration)s · \(insert.framing.mode.rawValue.capitalized)",
                isInsert: true, isGap: asset.isGap,
                mediaStatus: asset.isGap ? .online : mediaStatus(for: projectMediaURL(asset.file)))
        }
        let replacements = project.stillReplacements.compactMap { replacement -> StillPlacementRow? in
            guard let asset = assets[replacement.assetID], case .group(let bounds) = replacement.coverage else { return nil }
            let windows = assemblyGroupIndices.compactMap { index -> MulticamRange? in
                guard let range = assemblyRange(at: index) else { return nil }
                let lower = max(range.from, bounds.from)
                let upper = min(range.to, bounds.to)
                guard lower < upper,
                      let start = try? assemblyStart(at: index).adding(lower.subtracting(range.from)),
                      let end = try? assemblyStart(at: index).adding(upper.subtracting(range.from)) else { return nil }
                return .init(from: start, to: end)
            }
            let duration = (try? windows.reduce(RationalTime.zero) { sum, window in
                try sum.adding(window.to.subtracting(window.from))
            }) ?? .zero
            let resolved = windows.map { "\($0.from)–\($0.to)" }.joined(separator: ", ")
            let visible = windows.isEmpty ? "0s visible" : "Assembly \(resolved) · \(duration)s visible"
            return StillPlacementRow(id: replacement.id, title: asset.displayName, details:
                "Replace · Group \(bounds.from)–\(bounds.to) · \(visible) · \(replacement.framing.mode.rawValue.capitalized)",
                isInsert: false, mediaStatus: mediaStatus(for: projectMediaURL(asset.file)))
        }
        return inserts + replacements
    }

    func manageMulticamStill(_ row: StillPlacementRow, action: StillPlacementAction) {
        guard let project else { return }
        let document = CutProject.multicam(project)
        let insert = document.stillInserts.first { $0.id == row.id }
        let replacement = project.stillReplacements.first { $0.id == row.id }
        guard let assetID = insert?.assetID ?? replacement?.assetID else { return }
        let revision = mcpRevision
        if let replacement, [.move, .resize, .duplicate].contains(action) {
            StillPanels.editReplacement(replacement, action: action, in: window) { [weak self] request in
                guard let self, self.mcpRevision == revision else { return }
                self.performStillEditByHand(request.title) { document in
                    try request.apply(to: document) { time, _, _ in
                        guard project.range.contains(time) else { return time }
                        return self.stillReplacementBounds(.init(from: time, to: time)).from
                    }
                }
            }
            return
        }
        switch action {
        case .frame:
            guard let framing = insert?.framing ?? replacement?.framing else { return }
            StillPanels.frame(title: "Still Framing", framing: framing, gap: row.isGap, in: window) { [weak self] framing in
                guard let self, self.mcpRevision == revision else { return }
                self.performStillEditByHand("Change Still Framing") { try $0.updatingStill(id: row.id, assetID: assetID, framing: framing) }
            }
        case .move:
            guard let index = assemblyItems.firstIndex(where: { $0.still?.id == row.id }) else { return }
            StillPanels.text(title: "Move Still", label: "Assembly time (seconds)",
                             value: assemblyStart(at: index).description, in: window) { [weak self] text in
                guard let self, self.mcpRevision == revision else { return }
                if self.performStillEditByHand("Move Still", { document in
                    let requested = try RationalTime(parsing: text)
                    return try document.movingStill(id: row.id, to: self.snappedAssemblyStillPosition(requested))
                }), let inserted = self.assemblyItems.firstIndex(where: { $0.still?.id == row.id }) {
                    self.selectAssemblyOccurrence(inserted)
                }
            }
        case .resize:
            guard let insert else { return }
            StillPanels.duration(title: "Change Still Duration", duration: insert.duration,
                                 cadence: insert.cadence, in: window) { [weak self] duration, cadence in
                guard let self, self.mcpRevision == revision else { return }
                self.performStillEditByHand("Change Still Duration") { try $0.resizingStill(id: row.id, duration: duration, cadence: cadence) }
            }
        case .duplicate:
            guard var insert, let index = assemblyItems.firstIndex(where: { $0.still?.id == row.id }) else { return }
            insert.id = ProjectIdentifier.make()
            let end = assemblyRangeEnds[index]
            performStillEditByHand("Duplicate Still") { try $0.insertingStill(insert, at: end) }
        case .detach: return
        case .remove:
            performStillEditByHand("Delete Still") { try $0.removingStill(id: row.id) }
        case .relink:
            guard let asset = project.stillAssets.first(where: { $0.id == assetID && !$0.isGap }) else { return }
            presentProjectMedia(.locate, path: projectMediaURL(asset.file).path)
        }
    }

    func assemblyStillCut(at output: RationalTime) -> (still: StillInsert, offset: RationalTime)? {
        guard assemblyPreview else { return nil }
        let index = occurrenceIndex(at: output)
        guard let still = assemblyStill(at: index),
              let offset = try? output.subtracting(assemblyStart(at: index)),
              let frame = stillFrameBoundary(offset, cadence: still.cadence, nearest: true),
              .zero < frame, frame < still.duration else { return nil }
        return (still, frame)
    }
}

struct MulticamAssetSpan: Identifiable, Equatable {
    let id: String
    let title: String
    let interval: MulticamRange
    var frame: StillReviewFrame? = nil
    var mediaURL: URL?
    var mediaStatus: ProjectMediaStatus = .online

    static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.title == right.title && left.interval == right.interval &&
            left.mediaURL == right.mediaURL && left.mediaStatus == right.mediaStatus
    }
}

@MainActor
extension MulticamEditorModel {
    var groupStillFrames: [MulticamAssetSpan] {
        guard let project else { return [] }
        let document = CutProject.multicam(project)
        let assets = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0) })
        return project.stillReplacements.compactMap { replacement in
            guard case .group(let range) = replacement.coverage else { return nil }
            guard let asset = assets[replacement.assetID], !asset.isGap else { return nil }
            let url = projectMediaURL(asset.file)
            let status = mediaStatus(for: url)
            return .init(id: replacement.id, title: asset.displayName, interval: range,
                         frame: status.hidesMedia ? nil : try? document.stillReviewFrame(
                            placementID: replacement.id, interval: range, document: projectURL, canvas: stillReviewCanvas),
                         mediaURL: url, mediaStatus: status)
        }
    }

    var assemblyAssetSpans: [MulticamAssetSpan] {
        guard let project, !project.stillAssets.isEmpty else { return [] }
        let document = CutProject.multicam(project)
        guard let plan = try? document.resolveStills() else { return [] }
        let assets = Dictionary(uniqueKeysWithValues: project.stillAssets.filter { !$0.isGap }.map { ($0.id, $0) })
        let assetIDs = Dictionary(uniqueKeysWithValues:
            project.stillReplacements.map { ($0.id, $0.assetID) } + document.stillInserts.map { ($0.id, $0.assetID) })
        return plan.spans.enumerated().compactMap { index, span in
            guard let id = span.placementID, let assetID = assetIDs[id], let asset = assets[assetID] else { return nil }
            let url = projectMediaURL(asset.file)
            return .init(id: "\(id)-\(index)", title: asset.displayName, interval: span.output,
                         mediaURL: url, mediaStatus: mediaStatus(for: url))
        }
    }
}
