/*
CERRAR HUECOS SIN VIDEO - V2 (revision 5)
En cada tramo de la secuencia activa donde no hay video en ninguna pista, marca
entrada y salida y le pide a Premiere que lo EXTRAIGA. Premiere cierra el hueco
en todas las pistas a la vez, tambien las de subtitulos, que un script no puede
tocar directamente.
Los cierra todos de una vez, del ultimo al primero, sin preguntar. Cuando un
hueco separaba dos clips en una misma pista de video, agrega Cross Dissolve en
esa union. Antes de cada
extraccion calcula como debe quedar cada clip de video y audio, y despues lo
compara con la secuencia real; si no coincide, deshace ese paso y se detiene.
Ejecutar sobre una COPIA de la secuencia.
*/
(function () {
    var TPS = 254016000000;
    var TOL = 0.01;   // Fotogramas: tolerancia al comparar posiciones.
    // Premiere convierte los segundos a ticks truncando. Un punto de entrada que cae
    // un tick ANTES del fotograma hace que el video se corte un fotograma entero antes,
    // asi que a cada marca se le suma la fraccion de tick que la deja exacta.
    var MARGINS = [0, 0.5, 0.25, 0.75, 1, 2];
    var log = ["CERRAR HUECOS SIN VIDEO V2 (revision 5 · Cross Dissolve)"];
    function fail(s) { throw new Error(s); }
    function report(message) {
        log.push(message);
        var saved = "";
        try {
            var f = new File(File($.fileName).parent.fsName + "/Cerrar_Huecos_V2_diagnostico.txt");
            f.encoding = "UTF-8";
            if (f.open("w")) { f.write(log.join("\n")); f.close(); saved = "\n\nInforme: " + f.fsName; }
        } catch (ignore) {}
        alert(message + saved);
    }
    function byStart(x, y) { return x.s - y.s || x.e - y.e; }
    try {
        var seq = app.project.activeSequence;
        if (!seq) fail("Abre la secuencia.");
        var settings = seq.getSettings();
        var frameTicks = Number(seq.timebase);
        if (!isFinite(frameTicks) || frameTicks <= 0) frameTicks = Number(settings.videoFrameRate.ticks);
        if (!isFinite(frameTicks) || frameTicks <= 0) fail("No se pudo leer la duracion del fotograma.");
        var fps = TPS / frameTicks;
        var format = Number(seq.videoDisplayFormat);
        if (!isFinite(format)) format = Number(settings.videoDisplayFormat);
        var frameTime = new Time();
        frameTime.ticks = String(Math.round(frameTicks));
        function timecode(frame) {   // Solo para mensajes.
            try {
                var t = new Time();
                t.ticks = String(Math.round(frame * frameTicks));
                return String(t.getFormatted(frameTime, format));
            } catch (formatError) { return "frame " + frame; }
        }
        log.push("Secuencia: " + seq.name + "; ID: " + seq.sequenceID + "; FPS: " + fps + "; origen: " + seq.zeroPoint);

        // Posicion real de cada clip, por pista, y tramos sin video.
        function snapshot() {
            if (String(app.project.activeSequence.sequenceID) !== String(seq.sequenceID)) fail("Cambio la secuencia activa.");
            var tracks = [], video = [], videoTracks = [], end = 0, groups = [["V", seq.videoTracks], ["A", seq.audioTracks]], g, t, i;
            for (g = 0; g < groups.length; g++) for (t = 0; t < groups[g][1].numTracks; t++) {
                var list = [], clips = groups[g][1][t].clips;
                for (i = 0; i < clips.numItems; i++) {
                    var s = Number(clips[i].start.ticks) / frameTicks, e = Number(clips[i].end.ticks) / frameTicks;
                    if (!isFinite(s) || !isFinite(e) || e <= s) fail("Premiere devolvio un clip con tiempos invalidos.");
                    list.push({s: s, e: e});
                    if (g === 0) video.push({s: s, e: e});
                    end = Math.max(end, e);
                }
                list.sort(byStart);
                if (g === 0) videoTracks.push(list);
                tracks.push({name: groups[g][0] + (t + 1), clips: list});
            }
            video.sort(byStart);
            var gaps = [], cursor = 0;
            for (i = 0; i < video.length; i++) {
                // Menos de medio fotograma es residuo numerico, no una pausa.
                if (video[i].s - cursor > 0.5) gaps.push({s: Math.round(cursor), e: Math.round(video[i].s)});
                cursor = Math.max(cursor, video[i].e);
            }
            // La cola se quita entera aunque el audio termine a mitad de un fotograma.
            if (end - cursor > 0.5) gaps.push({s: Math.round(cursor), e: Math.ceil(end - TOL)});
            return {tracks: tracks, gaps: gaps, end: end, videoClips: video.length, videoTracks: videoTracks};
        }
        function lists(snap) {
            var out = [];
            for (var t = 0; t < snap.tracks.length; t++) out.push(snap.tracks[t].clips);
            return out;
        }
        // Como debe quedar cada pista al extraer el tramo: lo anterior igual, lo posterior
        // corrido, y lo que lo atraviesa (el microfono) partido sin su parte central.
        function expectedAfter(snap, gap) {
            var length = gap.e - gap.s, out = [], t, i;
            for (t = 0; t < snap.tracks.length; t++) {
                var src = snap.tracks[t].clips, list = [];
                for (i = 0; i < src.length; i++) {
                    var s = src[i].s, e = src[i].e;
                    if (e <= gap.s + TOL) list.push({s: s, e: e});
                    else if (s >= gap.e - TOL) list.push({s: s - length, e: e - length});
                    else {
                        if (gap.s - s > TOL) list.push({s: s, e: gap.s});
                        if (e - gap.e > TOL) list.push({s: gap.s, e: e - length});
                    }
                }
                out.push(list);
            }
            return out;
        }
        function differences(expected, snap) {
            var notes = [], t, i;
            for (t = 0; t < snap.tracks.length; t++) {
                var got = snap.tracks[t].clips, want = expected[t], name = snap.tracks[t].name;
                if (got.length !== want.length) { notes.push(name + ": " + got.length + " clips, debian ser " + want.length); continue; }
                for (i = 0; i < got.length; i++) {
                    if (Math.abs(got[i].s - want[i].s) > TOL || Math.abs(got[i].e - want[i].e) > TOL) {
                        notes.push(name + " clip " + (i + 1) + ": quedo en " + got[i].s + " - " + got[i].e + ", debia quedar en " + want[i].s + " - " + want[i].e);
                        break;
                    }
                }
            }
            return notes;
        }
        // Segundos que, al truncarse a ticks como hace Premiere, dan justo el tick pedido.
        function exactSeconds(ticks) {
            for (var m = 0; m < MARGINS.length; m++) {
                var seconds = (ticks + MARGINS[m]) / TPS;
                if (Math.floor(seconds * TPS) === ticks) return seconds;
            }
            return (ticks + 8) / TPS;   // Nunca antes: unos ticks tarde no cambian ningun fotograma.
        }
        function setMarks(gap) {
            var wantIn = Math.round(gap.s * frameTicks), wantOut = Math.round(gap.e * frameTicks);
            seq.setInPoint(exactSeconds(wantIn));
            seq.setOutPoint(exactSeconds(wantOut));
            // Se relee lo que Premiere guardo de verdad: nunca antes del fotograma pedido.
            var gotIn, gotOut;
            try {
                gotIn = Number(seq.getInPointAsTime().ticks);
                gotOut = Number(seq.getOutPointAsTime().ticks);
            } catch (readError) { log.push("  no se pudo releer entrada/salida: " + readError); return; }
            var zero = Number(seq.zeroPoint), dIn = gotIn - wantIn, dOut = gotOut - wantOut;
            if (isFinite(zero) && zero && Math.abs(dIn - zero) < Math.abs(dIn)) { dIn -= zero; dOut -= zero; }
            log.push("  marcas guardadas: entrada +" + dIn + " ticks, salida +" + dOut + " ticks");
            var limit = frameTicks * 0.001;
            if (!(dIn >= 0 && dIn < limit && dOut >= 0 && dOut < limit))
                fail("Premiere no dejo la entrada y la salida en los fotogramas pedidos (" + timecode(gap.s) + " a " + timecode(gap.e) + "). No se extrajo ese tramo.");
        }
        // Solo se aplica donde habia un clip que terminaba en el borde izquierdo
        // Y otro que empezaba en el borde derecho del hueco original. Un video que
        // aparecio o termino en ese punto no recibe una transicion inventada.
        function addCrossDissolves(before, gap) {
            var transition, added = 0, t, i, left, right, clips, qtrack, qclip;
            try { transition = qe.project.getVideoTransitionByName("Cross Dissolve"); }
            catch (transitionError) { log.push("  No se pudo localizar Cross Dissolve: " + transitionError); return 0; }
            if (!transition) { log.push("  No se encontro Cross Dissolve en esta instalacion; el hueco se cerro sin transicion."); return 0; }
            for (t = 0; t < before.videoTracks.length; t++) {
                left = right = false;
                for (i = 0; i < before.videoTracks[t].length; i++) {
                    if (Math.abs(before.videoTracks[t][i].e - gap.s) <= TOL) left = true;
                    if (Math.abs(before.videoTracks[t][i].s - gap.e) <= TOL) right = true;
                }
                if (!left || !right) continue;
                clips = seq.videoTracks[t].clips;
                for (i = 0; i < clips.numItems; i++) {
                    if (Math.abs(Number(clips[i].start.ticks) / frameTicks - gap.s) > TOL) continue;
                    try {
                        qtrack = qseq.getVideoTrackAt(t);
                        qclip = qtrack && qtrack.getItemAt(i);
                        if (!qclip || typeof qclip.addTransition !== "function") throw new Error("Premiere no expone addTransition en V" + (t + 1));
                        // En el inicio del clip entrante; 1 segundo de duracion, centrado en el corte.
                        qclip.addTransition(transition, true, "00:00:01:00", "00:00:00:00", 0.5);
                        added++;
                        log.push("  Cross Dissolve agregado en V" + (t + 1) + " en " + timecode(gap.s));
                    } catch (addError) { log.push("  No se pudo agregar Cross Dissolve en V" + (t + 1) + ": " + addError); }
                    break;
                }
            }
            return added;
        }

        var first = snapshot();
        if (!first.videoClips) fail("La secuencia no tiene clips de video.");
        if (!first.gaps.length) { report("No hay tramos sin video: la secuencia ya es continua. No se modifico nada."); return; }
        var i;
        for (i = 0; i < first.gaps.length; i++)
            log.push("Hueco frames: " + first.gaps[i].s + " - " + first.gaps[i].e + "  (" + timecode(first.gaps[i].s) + " a " + timecode(first.gaps[i].e) + ")");

        // Extraer actua sobre las pistas marcadas como destino: se marcan todas.
        var groups = [seq.videoTracks, seq.audioTracks], g, t;
        for (g = 0; g < groups.length; g++) for (t = 0; t < groups[g].numTracks; t++) {
            if (groups[g][t].isLocked()) fail("Hay una pista bloqueada (candado). Desbloqueala: si no, no se correria con las demas.");
            try { groups[g][t].setTargeted(true, true); } catch (targetError) { log.push("No se pudo marcar una pista como destino: " + targetError); }
        }
        app.enableQE();
        var qseq = qe.project.getActiveSequence();
        if (!qseq || typeof qseq.extract !== "function") fail("Esta version de Premiere no ofrece Extraer a los scripts. No se modifico nada.");
        // Una pista sin bloqueo de sincronizacion no se corre al extraer y se desfasa.
        for (t = 0; t < qseq.numVideoTracks + qseq.numAudioTracks; t++) {
            try {
                var qtrack = t < qseq.numVideoTracks ? qseq.getVideoTrackAt(t) : qseq.getAudioTrackAt(t - qseq.numVideoTracks);
                if (qtrack && !qtrack.isSyncLocked()) { qtrack.setSyncLock(true); log.push("Bloqueo de sincronizacion activado en pista " + (t + 1)); }
            } catch (syncError) { log.push("No se pudo revisar el bloqueo de sincronizacion: " + syncError); }
        }

        var done = 0, removed = 0, transitions = 0, skipped = [], guard = first.gaps.length + 2;
        while (guard-- > 0) {
            var now = snapshot();
            var index = now.gaps.length - 1 - skipped.length;   // del ultimo al primero
            if (index < 0) break;
            var gap = now.gaps[index];
            var label = timecode(gap.s) + " a " + timecode(gap.e);
            log.push("Tramo " + label + " (" + (gap.e - gap.s) + " frames)");
            var expected = expectedAfter(now, gap);
            setMarks(gap);
            try { qseq.extract(); } catch (extractError) { log.push("  extract: " + extractError); }
            var after = snapshot();
            if (!differences(lists(now), after).length) {
                log.push("  Premiere no extrajo nada; se deja como esta.");
                skipped.push(label);
                continue;
            }
            var notes = differences(expected, after);
            if (notes.length) {
                for (i = 0; i < notes.length && i < 12; i++) log.push("  " + notes[i]);
                var restored = false;
                for (var u = 0; u < 2 && !restored; u++) {
                    try { qe.project.undo(); } catch (undoError) { log.push("  undo: " + undoError); break; }
                    restored = !differences(lists(now), snapshot()).length;
                }
                fail("Al extraer " + label + " la secuencia no quedo como debia:\n" + notes[0] + "\n\n" +
                    (restored ? "Ese paso se deshizo solo; la secuencia quedo como estaba antes de el."
                              : "No pude deshacerlo: pulsa Ctrl+Z una vez.") +
                    "\nTramos cerrados correctamente antes: " + done + ".");
            }
            transitions += addCrossDissolves(now, gap);
            log.push("  extraido y comprobado");
            done++;
            removed += gap.e - gap.s;
        }
        var last = snapshot();
        report("Tramos sin video cerrados: " + done + " de " + first.gaps.length +
            "\nTiempo quitado: " + (removed / fps).toFixed(1) + " s" +
            "\nDuracion: " + (first.end / fps).toFixed(1) + " s -> " + (last.end / fps).toFixed(1) + " s" +
            "\nCross Dissolve agregados: " + transitions + " (solo donde el hueco unia dos videos)." +
            "\nCada clip de video y audio quedo donde debia tras cada extraccion." +
            (skipped.length ? "\n\nPremiere no extrajo " + skipped.length + " tramo(s): " + skipped.join("; ") : "") +
            "\n\nLos subtitulos los corre Premiere y un script no puede leerlos: dales un vistazo.");
    } catch (error) {
        report("V2 - " + String(error.message || error));
    }
})();
