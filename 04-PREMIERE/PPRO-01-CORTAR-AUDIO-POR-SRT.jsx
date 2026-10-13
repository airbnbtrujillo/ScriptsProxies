/*
CORTAR AUDIO POR SRT - V7
Lee los FPS y el formato de tiempo de la secuencia.
Redondea una sola vez los limites SRT a fotogramas.
Repara cortes faltantes y elimina solamente segmentos fuera del SRT, sin ripple.
Ejecutar sobre una copia de la pista. No reconstruye audio borrado previamente.
Referencia API: https://github.com/Adobe-CEP/Samples/tree/master/PProPanel
*/
(function () {
    var TPS = 254016000000;
    var EPS = 0.00001; // Fraccion de fotograma: error numerico, no margen de voz.
    var log = ["CORTAR AUDIO SRT V7"];
    function trim(s) { return String(s).replace(/^\s+|\s+$/g, ""); }
    function fail(s) { throw new Error(s); }
    function numeric(s) {
        s = trim(s).replace(",", ".");
        if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(s)) fail("Numero invalido: " + s);
        var n = Number(s);
        if (!isFinite(n)) fail("Numero invalido.");
        return n;
    }
    function merge(a) {
        a.sort(function (x, y) { return x.s - y.s; });
        var out = [], i, last;
        for (i = 0; i < a.length; i++) {
            last = out.length ? out[out.length - 1] : null;
            if (last && a[i].s <= last.e + EPS) last.e = Math.max(last.e, a[i].e);
            else out.push({s: a[i].s, e: a[i].e});
        }
        return out;
    }
    function parse(text, offset, fps) {
        var re = /(\d{1,3}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{1,3}):(\d{2}):(\d{2})[,.](\d{3})/g;
        var m, ranges = [], seen = 0;
        function seconds(k) {
            if (+m[k + 1] > 59 || +m[k + 2] > 59) fail("Tiempo SRT invalido.");
            return +m[k] * 3600 + +m[k + 1] * 60 + +m[k + 2] + +m[k + 3] / 1000;
        }
        while ((m = re.exec(text)) !== null) {
            seen++;
            var s = seconds(1), e = seconds(5);
            if (e <= s) fail("Intervalo SRT invertido o vacio.");
            var center = (s + e) / 2 + offset;
            s = Math.max(0, Math.round((s + offset) * fps));
            e = Math.round((e + offset) * fps);
            if (e <= 0) continue;
            if (e <= s) {
                // Subtitulos de 20 ms: conservar el fotograma que contiene su centro.
                s = Math.max(0, Math.floor(center * fps));
                e = s + 1;
                log.push("Subtitulo " + seen + " menor de un fotograma: conservado frame " + s);
            }
            ranges.push({s: s, e: e});
        }
        if ((text.match(/-->/g) || []).length !== seen) fail("Hay tiempos SRT que no se pudieron leer.");
        if (!ranges.length) fail("El SRT no tiene intervalos utilizables.");
        return merge(ranges);
    }
    function classify(c, ranges) {
        var i;
        for (i = 0; i < ranges.length; i++) {
            if (c.s >= ranges[i].s - EPS && c.e <= ranges[i].e + EPS) return 1;
        }
        for (i = 0; i < ranges.length; i++) {
            if (Math.min(c.e, ranges[i].e) - Math.max(c.s, ranges[i].s) > EPS) return -1;
        }
        return 0;
    }
    function sameRanges(a, b) {
        if (a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++)
            if (Math.abs(a[i].s - b[i].s) > EPS || Math.abs(a[i].e - b[i].e) > EPS) return false;
        return true;
    }
    function intersection(clips, ranges) {
        var out = [], i, j, s, e;
        for (i = 0; i < clips.length; i++) for (j = 0; j < ranges.length; j++) {
            s = Math.max(clips[i].s, ranges[j].s);
            e = Math.min(clips[i].e, ranges[j].e);
            if (e - s > EPS) out.push({s:s, e:e});
        }
        return merge(out);
    }
    function report(message) {
        log.push(message);
        var saved = "";
        try {
            var f = new File(File($.fileName).parent.fsName + "/Cortar_Audio_V7_diagnostico.txt");
            f.encoding = "UTF-8";
            if (f.open("w")) { f.write(log.join("\n")); f.close(); saved = "\n\nInforme: " + f.fsName; }
        } catch (ignore) {}
        alert(message + saved);
    }
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
        // Si la regla muestra frames o muestras, elegir un timecode compatible.
        if (format < 100 || format > 110 || format === 109) {
            var rates = [24,25,30000/1001,30,50,60000/1001,60,24000/1001];
            var formats = [100,101,103,104,105,107,108,110];
            format = -1;
            for (var ri=0; ri<rates.length; ri++) if (Math.abs(fps-rates[ri]) < 0.001) format=formats[ri];
            if (format < 0) fail("Formato de tiempo no compatible.");
        }
        var frameTime = new Time();
        frameTime.ticks = String(Math.round(frameTicks));
        function timecode(frame) {
            var t = new Time();
            t.ticks = String(Math.round(frame * frameTicks));
            return String(t.getFormatted(frameTime, format));
        }
        log.push("Secuencia: " + seq.name + "; ID: " + seq.sequenceID);
        log.push("FPS reales: " + fps + "; ticks/frame: " + frameTicks + "; formato: " + format);
        log.push("Origen de secuencia (ticks): " + seq.zeroPoint);

        var file = File.openDialog("V7 - Elige el SRT", "Archivos SRT:*.srt");
        if (!file) return;
        file.encoding = "UTF-8";
        if (!file.open("r")) fail("No se pudo abrir el SRT.");
        var srt = file.read(); file.close();
        var trackText = prompt("V7 - Pista de audio DUPLICADA que quieres limpiar. A1=1, A2=2...\nFPS detectados: " + fps.toFixed(6), "1");
        if (trackText === null) return;
        var index = numeric(trackText) - 1;
        if (index < 0 || index !== Math.floor(index) || index >= seq.audioTracks.numTracks) fail("Pista invalida.");
        var offsetText = prompt("Desplazamiento del SRT en segundos. Si ya coincide con los subtitulos, deja 0.\nNo se agrega margen de audio.", "0");
        if (offsetText === null) return;
        var ranges = parse(srt, numeric(offsetText), fps);
        log.push("SRT: " + file.fsName + "; pista A" + (index+1) + "; offset: " + offsetText);
        for (var r=0;r<ranges.length;r++) log.push("SRT frames: " + ranges[r].s + " - " + ranges[r].e);
        function snapshot() {
            if (String(app.project.activeSequence.sequenceID) !== String(seq.sequenceID)) fail("Cambio la secuencia activa.");
            var track = seq.audioTracks[index], out = [];
            for (var i=0;i<track.clips.numItems;i++) {
                var c = track.clips[i];
                var s = Number(c.start.ticks) / frameTicks, e = Number(c.end.ticks) / frameTicks;
                if (!isFinite(s) || !isFinite(e) || e <= s) fail("Premiere devolvio un clip con tiempos invalidos.");
                out.push({s:s, e:e, clip:c, id:String(c.nodeId)});
            }
            return out;
        }
        var original = snapshot();
        if (!original.length) fail("La pista elegida esta vacia.");
        var expected = intersection(original, ranges);
        if (!expected.length) fail("Ningun audio coincide con el SRT. No se modifico la pista.");
        var originalCoverage = merge(original);
        var needed = [], b, i, j;
        for (r=0;r<ranges.length;r++) for (b=0;b<2;b++) {
            var point = b ? ranges[r].e : ranges[r].s;
            for (i=0;i<original.length;i++) {
                if (point > original[i].s + EPS && point < original[i].e - EPS) { needed.push(point); break; }
            }
        }
        log.push("Clips iniciales: " + original.length + "; limites que requieren corte: " + needed.length);
        var cutErrors = [];
        if (needed.length) {
            app.enableQE();
            var qseq = qe.project.getActiveSequence();
            if (!qseq) fail("No se pudo obtener la secuencia QE.");
            var qt = qseq.getAudioTrackAt(index);
            if (!qt) fail("No se pudo obtener la pista QE.");
            for (i=needed.length-1;i>=0;i--) {
                var tc = timecode(needed[i]);
                try { qt.razor(tc); } catch (cutError) { cutErrors.push(tc + ": " + cutError); }
                log.push("Corte frame " + needed[i] + ": " + tc);
            }
        }
        // El resultado real es la prueba. No interpretar valores QE no documentados.
        var current = snapshot(), keep = [], remove = [], mixed = [];
        for (i=0;i<current.length;i++) {
            var kind = classify(current[i], ranges);
            if (kind === 1) keep.push(current[i]);
            else if (kind === 0) remove.push(current[i]);
            else mixed.push(current[i]);
        }
        log.push("Conservar: " + keep.length + "; eliminar: " + remove.length + "; sin segmentar: " + mixed.length);
        for (i=0;i<mixed.length;i++) log.push("Clip sin segmentar (frames): " + mixed[i].s + " - " + mixed[i].e);
        if (cutErrors.length) log.push(cutErrors.join("\n"));
        if (!sameRanges(originalCoverage, merge(current))) fail("La cobertura del audio cambio al cortar. No se borro ningun clip.");
        if (mixed.length) {
            fail("V7: se solicitaron los cortes con los FPS reales (" + fps.toFixed(6) + "), pero " + mixed.length +
                " clips aun atraviesan un limite.\nNo se borro ningun clip.\nEjecuta V7 otra vez para verificar el estado actualizado. Si se repite, el informe contiene los cortes exactos.");
        }
        if (!keep.length || !sameRanges(expected, merge(keep))) fail("La cobertura a conservar no coincide. No se borro ningun clip.");

        // El plan ya esta completo. Quitar de atras hacia delante, sin ripple.
        var removed = 0;
        for (i=remove.length-1;i>=0;i--) {
            var target = remove[i], live = snapshot(), found = null;
            for (j=0;j<live.length;j++) {
                if (live[j].id === target.id && Math.abs(live[j].s-target.s)<EPS && Math.abs(live[j].e-target.e)<EPS) { found=live[j]; break; }
            }
            if (!found) fail("Cambio un clip del plan; borrados verificados: " + removed);
            found.clip.remove(false, false);
            var after = snapshot();
            var wanted = [];
            for (j=0;j<live.length;j++) if (live[j] !== found) wanted.push(live[j]);
            if (after.length !== wanted.length) fail("Premiere no confirmo la eliminacion. Borrados verificados: " + removed);
            for (j=0;j<after.length;j++) {
                if (after[j].id !== wanted[j].id || Math.abs(after[j].s-wanted[j].s)>EPS || Math.abs(after[j].e-wanted[j].e)>EPS)
                    fail("Cambio inesperado en la pista durante el borrado. Revisa el historial.");
            }
            removed++;
        }
        var finalClips = snapshot();
        if (!finalClips.length || !sameRanges(merge(finalClips), expected)) fail("La cobertura final no coincide con la prevista.");
        for (i=0;i<finalClips.length;i++) if (classify(finalClips[i], ranges)!==1) fail("Quedan clips fuera del SRT.");
        report("V7: limpieza verificada en A" + (index+1) + ".\nFPS reales: " + fps.toFixed(6) +
            "\nClips conservados: " + finalClips.length + "\nClips borrados: " + removed +
            "\nAudio fuera de los intervalos SRT: 0.\nLimites ajustados al fotograma mas cercano. Huecos sin ripple.");
    } catch (error) {
        report("V7 - " + String(error.message || error));
    }
})();
