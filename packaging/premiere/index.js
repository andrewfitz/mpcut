const { storage } = require("uxp");
const premiere = require("premierepro");
const protocolVersion = 3;
let busy = false;
let lastHeartbeat = 0;

async function nativeAngles(sequence, reading) {
    const angles = [];
    async function scanTrack(track) {
        for (const item of await track.getTrackItems(premiere.Constants.TrackItemType.CLIP, false)) {
            const source = premiere.ClipProjectItem.cast(await item.getProjectItem());
            if (source && await source.isMulticamClip()) {
                if (reading) throw Error("This Premiere sequence contains native multicam clips. Duplicate the sequence, flatten its multicam clips in Premiere, then export that copy. For a round-trip export from MPCut use --flatten-multicam --allow-loss.");
                // Premiere assigns this label while importing each multiclip. Verify it only
                // on our freshly generated project, where users have never renamed an item.
                const name = await item.getName();
                const suffix = "]-" + source.name;
                const match = name.endsWith(suffix) && name.slice(0, -suffix.length).match(/\[(\d+)$/);
                if (!match) throw Error("Premiere could not confirm the active native angle.");
                angles.push(Number(match[1]));
            }
        }
    }
    const videoTrackCount = await sequence.getVideoTrackCount();
    for (let i = 0; i < videoTrackCount; i++) await scanTrack(await sequence.getVideoTrack(i));
    if (reading) {
        const audioTrackCount = await sequence.getAudioTrackCount();
        for (let i = 0; i < audioTrackCount; i++) await scanTrack(await sequence.getAudioTrack(i));
    }
    return angles;
}

async function convert(job) {
    if (job.protocol_version !== protocolVersion) throw Error("Install the matching MPCut Premiere.ccx and restart Premiere.");
    let project;
    const warnings = [];
    if (job.operation === "write") {
        project = await premiere.Project.createProject(job.project_path);
        if (!project) throw Error("Premiere could not create the staged project.");
        try {
            if (!await project.importFiles([job.timeline_xml_path], true, await project.getRootItem(), false))
                throw Error("Premiere could not import the timeline.");
            const sequences = await project.getSequences();
            if (sequences.length !== 1) throw Error("Premiere did not create one sequence.");
            await project.openSequence(sequences[0]);
            if (!await project.save()) throw Error("Premiere could not save the project.");
        } finally {
            await project.close(new premiere.CloseProjectOptions().setPromptIfDirty(false));
        }
        const reopened = await premiere.Project.open(job.project_path, new premiere.OpenProjectOptions().setShowLocateFileDialog(false));
        if (!reopened) throw Error("Premiere could not reopen the saved project.");
        try {
            const sequence = (await reopened.getSequences())[0];
            if (!sequence) throw Error("The reopened Premiere project has no sequence.");
            const angles = await nativeAngles(sequence, false);
            if (JSON.stringify(angles) !== JSON.stringify(job.expected_angle_numbers))
                throw Error("The native multicam angles in the reopened Premiere project differ from the requested edit.");
        } finally {
            await reopened.close(new premiere.CloseProjectOptions().setPromptIfDirty(false));
        }
    } else if (job.operation === "read") {
        const options = new premiere.OpenProjectOptions();
        options.setShowLocateFileDialog(false);
        options.setShowWarningDialog(false);
        options.setAddToMRUList(false);
        project = await premiere.Project.open(job.project_path, options);
        if (!project) throw Error("Premiere could not open the project.");
        try {
            const sequences = await project.getSequences();
            if (!sequences.length) throw Error("The Premiere project contains no sequences.");
            if (sequences.length > 1) {
                if (!job.allow_loss) throw Error("The Premiere project has multiple sequences. Use --allow-loss to import its active or first sequence.");
                warnings.push("Imported one Premiere sequence from a project containing " + sequences.length + ".");
            }
            const sequence = await project.getActiveSequence() || sequences[0];
            await nativeAngles(sequence, true);
            if (!await premiere.ProjectConverter.exportAsFinalCutProXML(sequence, job.timeline_xml_path, true))
                throw Error("Premiere could not translate the sequence.");
        } finally {
            // The CLI supplied a uniquely named copy, so this project belongs to this job.
            await project.close(new premiere.CloseProjectOptions().setPromptIfDirty(false));
        }
    } else throw Error("Unknown conversion operation.");
    return { warnings };
}

async function poll() {
    if (busy) return;
    busy = true;
    try {
        const directory = await storage.localFileSystem.getDataFolder();
        if (Date.now() - lastHeartbeat > 2000) {
            const ready = await directory.createFile("ready-v" + protocolVersion, { overwrite: true });
            await ready.write("1");
            lastHeartbeat = Date.now();
        }
        for (const entry of await directory.getEntries()) {
            if (!/^job-[0-9a-f-]+\.json$/i.test(entry.name)) continue;
            const responseName = entry.name.replace("job-", "result-");
            let payload;
            try {
                payload = await entry.read();
                await entry.delete();
            } catch (error) {
                // The client may have removed a timed-out request after enumeration.
                document.getElementById("status").textContent = String(error);
                continue;
            }
            let result;
            try { result = await convert(JSON.parse(payload)); }
            catch (error) { result = { error: String(error) }; }
            try {
                const response = await directory.createFile(responseName);
                await response.write(JSON.stringify(result));
                document.getElementById("status").textContent = result.error || "Conversion completed. Ready for MPCut.";
            } catch (error) {
                document.getElementById("status").textContent = String(error);
            }
        }
    } catch (error) { document.getElementById("status").textContent = String(error); }
    finally { busy = false; }
}

setInterval(poll, 500);
poll();
