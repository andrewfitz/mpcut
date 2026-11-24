import AppKit
import MPCutCore
import SwiftUI

extension ProjectMediaSnapshot {
    var ignoredPaths: Set<String> {
        Set(entries.lazy.filter { $0.ignored == true }.map(\.path))
    }
}

@MainActor
final class ProjectMediaSummaryPaths {
    private struct Key: Equatable {
        let generation: UUID
        let revision: Int
        let document: URL
    }

    private var key: Key?
    private var urls: Set<URL> = []

    func invalidate() { key = nil }

    func summary(generation: UUID, revision: Int, document: URL, project: @autoclosure () -> CutProject,
                 status: (URL) -> ProjectMediaStatus) -> ProjectMediaAlertSummary {
        let current = Key(generation: generation, revision: revision, document: document)
        if key != current {
            // Planned multicam spans reuse paths already listed by the sources.
            let paths = Set(ProjectMedia.references(in: project(), includePlannedSpans: false).lazy
                .filter { $0.kind != .original }
                .map(\.path))
            urls = Set(paths.map { ProjectMediaVolume.watchURL($0, relativeTo: document) })
            key = current
        }
        return .init(urls.map(status))
    }
}

@MainActor
extension EditorModel {
    func presentProjectMedia(_ action: ProjectMediaAction = .show, path: String? = nil,
                             useID: String? = nil, offlineOnly: Bool = false) {
        if action == .reveal, let path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        preview.pause()
        projectMediaRequest = .init(path: path, action: action, useID: useID, offlineOnly: offlineOnly)
    }

    var projectMediaSummary: ProjectMediaAlertSummary {
        guard !isEmpty || !stillProject.stillAssets.isEmpty || hasHistory || projectURL != nil else { return .init([]) }
        return projectMediaSummaryPaths.summary(generation: mcpGeneration, revision: mcpRevision,
                                                document: projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL,
                                                project: transcriptProject, status: mediaStatus(for:))
    }

    func showProjectMediaUse(_ use: ProjectMediaUse) {
        if use.kind == .stillSoundtrack {
            seek(0)
            return
        }
        let occurrence = use.kind == .stillFragment ? use.id.split(separator: "/").last.map(String.init) ?? use.id : use.id
        if let id = try? stillReviewOccurrenceID(occurrence), let index = timelineClips.firstIndex(where: { $0.id == id }) {
            select(id)
            let start = timelineClips[index].sequenceRange?.lowerBound ?? timelineClips[..<index].reduce(0) { $0 + $1.duration }
            seek(start)
        } else if use.kind == .still,
                  let span = stillAssetSpans.first(where: { $0.mediaURL?.path == use.path }) {
            seek(span.interval.from.seconds)
        }
    }

    func actOnTimelineMedia(_ action: ProjectMediaAction, clip: TimelineClip) {
        guard let url = clip.mediaURL else { return }
        let useID = projectMediaUseID(for: clip.id)
        presentProjectMedia(action, path: url.path, useID: useID)
    }
}

@MainActor
extension MulticamEditorModel {
    func presentProjectMedia(_ action: ProjectMediaAction = .show, path: String? = nil,
                             useID: String? = nil, offlineOnly: Bool = false) {
        if action == .reveal, let path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        preview.pause()
        projectMediaRequest = .init(path: path, action: action, useID: useID, offlineOnly: offlineOnly)
    }

    var projectMediaSummary: ProjectMediaAlertSummary {
        guard let project else { return .init([]) }
        return projectMediaSummaryPaths.summary(generation: mcpGeneration, revision: mcpRevision,
                                                document: projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL,
                                                project: .multicam(project), status: mediaStatus(for:))
    }

    func showProjectMediaUse(_ use: ProjectMediaUse) {
        guard let project else { return }
        if use.kind == .still {
            if let span = groupStillFrames.first(where: { $0.mediaURL?.path == use.path }) {
                seekGroup(span.interval.from)
            } else if let index = assemblyItems.firstIndex(where: { $0.still?.assetID == use.id }) {
                selectAssemblyOccurrence(index)
            }
            return
        }
        guard let source = project.sources.first(where: { $0.id == use.id }) ??
                project.sources.first(where: { projectMediaURL($0.file).path == use.path }) else { return }
        if use.kind == .multicamSpan, let from = use.range?.from, let group = try? from.adding(source.offset) {
            seekGroup(group)
        } else {
            seekGroup(max(.zero, source.coverage?.from ?? source.offset))
        }
        if let marker = project.switches.last(where: { $0.at <= currentGroupTime() }), marker.angle == source.id {
            selectMarker(marker.at)
        }
    }

    func projectMediaPreviewURL(at output: RationalTime) -> URL? {
        guard let project else { return nil }
        let group = groupTime(at: output)
        let still = assemblyPreview ? assemblyStillCut(at: output)?.still.assetID : nil
        let replacement = project.stillReplacements.first {
            guard case .group(let range) = $0.coverage else { return false }
            return range.contains(group)
        }?.assetID
        if let assetID = still ?? replacement,
           let asset = project.stillAssets.first(where: { $0.id == assetID }) {
            return asset.isGap ? nil : projectMediaURL(asset.file)
        }
        guard let active = interval(at: output) else { return nil }
        return (active.pictureSourceID.flatMap { id in project.pictureSources.first { $0.id == id } }
                ?? project.pictureSource(for: active.angle, at: group)).map { projectMediaURL($0.file) }
    }

    func projectMediaURL(_ path: String) -> URL {
        ProjectMediaVolume.watchURL(path, relativeTo: projectURL ?? draft.url ?? LiveProjectMediaArchive.untitledURL)
    }
}
