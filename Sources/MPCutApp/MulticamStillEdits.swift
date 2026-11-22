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
        let reference = retained ?? snapshot.angles.lazy.compactMap { self.media[$0.id]?.videoStream }.first
        guard let reference, let policy = try? StillProgramColorPolicy.resolving(source: reference) else { return document }
        return try document.settingStillColorPolicy(policy)
    }

    private func stillPresentationBoundary(_ time: RationalTime) -> RationalTime {
        guard let project, time != project.range.from, time != project.range.to else { return time }
        guard let selection = project.selection(at: time), selection.at != time else { return time }
        guard let source = project.angles.first(where: { $0.id == selection.angle }),
              let frames = media[selection.angle]?.frames, !frames.isEmpty,
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
        guard let id = project?.selection(at: time)?.angle ?? project?.switches.last?.angle,
              let info = media[id], info.hasFullEditIndex, let rate = info.videoStream?.frameRate, rate > .zero else {
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
        guard canReplaceMulticamPicture else { return }
        let revision = mcpRevision
        StillPanels.chooseImage(in: window) { [weak self] url in
            guard let self, self.mcpRevision == revision else { return }
            self.replaceMulticamPicture(with: url)
        }
    }

    func replaceMulticamPicture(with url: URL) {
        guard let span = markedGroupSpan else { return }
        let bounds = stillReplacementBounds(span)
        addMulticamStill(url, title: "Replace Picture") { document, asset in
            try document.addingStillReplacement(.init(id: UUID().uuidString, assetID: asset.id,
                                                       framing: .fit, coverage: .group(bounds)))
        }
    }

    func chooseInsertMulticamStill() {
        guard !isBusy, project != nil else { return }
        let revision = mcpRevision
        StillPanels.chooseImage(in: window) { [weak self] url in
            guard let self, self.mcpRevision == revision else { return }
            self.insertMulticamStill(url)
        }
    }

    func insertMulticamStill(_ url: URL, atAssembly explicitTime: RationalTime? = nil) {
        insertMulticamStills([url], atAssembly: explicitTime)
    }

    func insertMulticamStills(_ urls: [URL], atAssembly explicitTime: RationalTime? = nil) {
        guard !urls.isEmpty, !isBusy, project != nil else { return }
        let group = currentGroupTime()
        guard let requested = explicitTime ?? (assemblyPreview ? preview.currentTime() : assemblyPosition(for: group)) else {
            fail("The group playhead is outside the assembled ranges. Choose an insertion point in the assembly.")
            return
        }
        let position = snappedAssemblyStillPosition(requested)
        let cadence = multicamStillCadence(atGroup: group) ?? .init(numerator: 1, denominator: 30)
        let duration = max(cadence, stillFrameBoundary(.init(numerator: 2), cadence: cadence, nearest: true) ?? cadence)
        let revision = mcpRevision
        let title = urls.count == 1 ? "Insert Still" : "Insert \(urls.count) Stills"
        StillPanels.duration(title: "\(title) at Assembly Time \(position)", duration: duration,
                             cadence: cadence, in: window) { [weak self] duration, cadence in
            guard let self, self.mcpRevision == revision else { return }
            var ids: [String] = []
            if self.performStillEdit(title, { project in
                var document = project
                var at = position
                for url in urls {
                    let asset = try StillPanels.asset(for: url, existing: document.stillAssets)
                    let id = UUID().uuidString
                    ids.append(id)
                    document = try document.addingStillAsset(asset)
                    document = try document.insertingStill(.init(id: id, assetID: asset.id, duration: duration,
                                                                 cadence: cadence), at: at)
                    at = try at.adding(duration)
                }
                return document
            }), let index = self.assemblyItems.firstIndex(where: { $0.still.map { $0.id == ids.first } == true }) {
                self.selectAssemblyOccurrence(index)
            }
        }
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

    @discardableResult
    private func addMulticamStill(_ url: URL, title: String,
                                  change: (CutProject, StillAsset) throws -> CutProject) -> Bool {
        performStillEdit(title) { document in
            let asset = try StillPanels.asset(for: url, existing: document.stillAssets)
            return try change(document.addingStillAsset(asset), asset)
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
                "Insert · Assembly \(assemblyStart(at: index))–\(assemblyRangeEnds[index]) · \(insert.duration)s · \(insert.framing.mode.rawValue.capitalized)\(stillOffline(asset))",
                isInsert: true)
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
                "Replace · Group \(bounds.from)–\(bounds.to) · \(visible) · \(replacement.framing.mode.rawValue.capitalized)\(stillOffline(asset))",
                isInsert: false)
        }
        return inserts + replacements
    }

    private func stillOffline(_ asset: StillAsset) -> String {
        FileManager.default.isReadableFile(atPath: asset.file) ? "" : " · Offline"
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
                self.performStillEdit(request.title) { document in
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
            StillPanels.frame(title: "Still Framing", framing: framing, in: window) { [weak self] framing in
                guard let self, self.mcpRevision == revision else { return }
                self.performStillEdit("Change Still Framing") { try $0.updatingStill(id: row.id, assetID: assetID, framing: framing) }
            }
        case .move:
            guard let index = assemblyItems.firstIndex(where: { $0.still?.id == row.id }) else { return }
            StillPanels.text(title: "Move Still", label: "Assembly time (seconds)",
                             value: assemblyStart(at: index).description, in: window) { [weak self] text in
                guard let self, self.mcpRevision == revision else { return }
                if self.performStillEdit("Move Still", { document in
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
                self.performStillEdit("Change Still Duration") { try $0.resizingStill(id: row.id, duration: duration, cadence: cadence) }
            }
        case .duplicate:
            guard var insert, let index = assemblyItems.firstIndex(where: { $0.still?.id == row.id }) else { return }
            insert.id = UUID().uuidString
            let end = assemblyRangeEnds[index]
            performStillEdit("Duplicate Still") { try $0.insertingStill(insert, at: end) }
        case .detach: return
        case .remove:
            performStillEdit("Delete Still") { try $0.removingStill(id: row.id) }
        case .relink:
            StillPanels.chooseImage(in: window) { [weak self] url in
                guard let self, self.mcpRevision == revision else { return }
                self.performStillEdit("Relink Still Image") {
                    let asset = try StillPanels.asset(for: url, existing: [])
                    return try $0.relinkingStillAsset(assetID, file: asset.file, fingerprint: asset.fingerprint)
                }
            }
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

    static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.title == right.title && left.interval == right.interval
    }
}

@MainActor
extension MulticamEditorModel {
    var groupStillFrames: [MulticamAssetSpan] {
        guard let project else { return [] }
        let document = CutProject.multicam(project)
        let names = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0.displayName) })
        return project.stillReplacements.compactMap { replacement in
            guard case .group(let range) = replacement.coverage else { return nil }
            return .init(id: replacement.id, title: names[replacement.assetID] ?? replacement.assetID, interval: range,
                         frame: try? document.stillReviewFrame(placementID: replacement.id, interval: range,
                                                               document: projectURL, canvas: stillReviewCanvas))
        }
    }

    var assemblyAssetSpans: [MulticamAssetSpan] {
        guard let project, !project.stillAssets.isEmpty else { return [] }
        let document = CutProject.multicam(project)
        guard let plan = try? document.resolveStills() else { return [] }
        let names = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0.displayName) })
        let assetIDs = Dictionary(uniqueKeysWithValues:
            project.stillReplacements.map { ($0.id, $0.assetID) } + document.stillInserts.map { ($0.id, $0.assetID) })
        return plan.spans.enumerated().compactMap { index, span in
            guard let id = span.placementID, let asset = assetIDs[id] else { return nil }
            return .init(id: "\(id)-\(index)", title: names[asset] ?? asset, interval: span.output)
        }
    }
}
