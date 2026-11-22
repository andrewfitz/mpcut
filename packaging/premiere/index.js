const { storage } = require("uxp");
const premiere = require("premierepro");
let busy = false;
let lastHeartbeat = 0;

async function nativeAngles(sequence, reading) {
    const angles = [];
    const tracks = [];
    for (let i = 0; i < await sequence.getVideoTrackCount(); i++) tracks.push(await sequence.getVideoTrack(i));
    if (reading) {
        for (let i = 0; i < await sequence.getAudioTrackCount(); i++) tracks.push(await sequence.getAudioTrack(i));
    }
    for (const track of tracks) {
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
    return angles;
}

async function convert(job) {
    if (job.protocol !== 2) throw Error("Install the matching MPCut Premiere.ccx and restart Premiere.");
    let project;
    const warnings = [];
    if (job.operation === "write") {
        project = await premiere.Project.createProject(job.project);
        if (!project) throw Error("Premiere could not create the staged project.");
        try {
            if (!await project.importFiles([job.timeline], true, await project.getRootItem(), false))
                throw Error("Premiere could not import the timeline.");
            const sequences = await project.getSequences();
            if (sequences.length !== 1) throw Error("Premiere did not create one sequence.");
            await project.openSequence(sequences[0]);
            if (!await project.save()) throw Error("Premiere could not save the project.");
        } finally {
            await project.close(new premiere.CloseProjectOptions().setPromptIfDirty(false));
        }
        const reopened = await premiere.Project.open(job.project, new premiere.OpenProjectOptions().setShowLocateFileDialog(false));
        if (!reopened) throw Error("Premiere could not reopen the saved project.");
        try {
            const sequence = (await reopened.getSequences())[0];
            if (!sequence) throw Error("The reopened Premiere project has no sequence.");
            const angles = await nativeAngles(sequence, false);
            if (JSON.stringify(angles) !== JSON.stringify(job.expectedAngles))
                throw Error("The native multicam angles in the reopened Premiere project differ from the requested edit.");
        } finally {
            await reopened.close(new premiere.CloseProjectOptions().setPromptIfDirty(false));
        }
    } else if (job.operation === "read") {
        const options = new premiere.OpenProjectOptions();
        options.setShowLocateFileDialog(false);
        options.setShowWarningDialog(false);
        options.setAddToMRUList(false);
        project = await premiere.Project.open(job.project, options);
        if (!project) throw Error("Premiere could not open the project.");
        try {
            const sequences = await project.getSequences();
            if (!sequences.length) throw Error("The Premiere project contains no sequences.");
            if (sequences.length > 1) {
                if (!job.allowLoss) throw Error("The Premiere project has multiple sequences. Use --allow-loss to import its active or first sequence.");
                warnings.push("Imported one Premiere sequence from a project containing " + sequences.length + ".");
            }
            const sequence = await project.getActiveSequence() || sequences[0];
            await nativeAngles(sequence, true);
            if (!await premiere.ProjectConverter.exportAsFinalCutProXML(sequence, job.timeline, true))
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
            const ready = await directory.createFile("ready", { overwrite: true });
            await ready.write("1");
            lastHeartbeat = Date.now();
        }
        for (const entry of await directory.getEntries()) {
            if (!/^job-[0-9a-f-]+\.json$/i.test(entry.name)) continue;
            const job = JSON.parse(await entry.read());
            const responseName = entry.name.replace("job-", "result-");
            await entry.delete();
            let result;
            try { result = await convert(job); }
            catch (error) { result = { error: String(error) }; }
            const response = await directory.createFile(responseName);
            await response.write(JSON.stringify(result));
            document.getElementById("status").textContent = result.error || "Conversion completed. Ready for MPCut.";
        }
    } catch (error) { document.getElementById("status").textContent = String(error); }
    finally { busy = false; }
}

setInterval(poll, 500);
poll();
