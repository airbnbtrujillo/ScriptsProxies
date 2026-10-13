/*
DIAGNOSTICO API PREMIERE
No modifica nada. Escribe en Diagnostico_API_Premiere.txt que funciones ofrece
esta version de Premiere para la secuencia activa, para saber si un script
puede extraer tramos (ripple en todas las pistas) o tocar los subtitulos.
*/
(function () {
    var out = ["DIAGNOSTICO API PREMIERE", "Version: " + app.version];
    function names(list) {
        var a = [];
        for (var i = 0; i < list.length; i++) a.push(String(list[i].name));
        a.sort();
        return a.join(", ");
    }
    function dump(label, obj) {
        try {
            out.push("", "== " + label, "METODOS: " + names(obj.reflect.methods), "PROPIEDADES: " + names(obj.reflect.properties));
        } catch (error) { out.push("", "== " + label, "No disponible: " + error); }
    }
    try {
        var seq = app.project.activeSequence;
        if (!seq) throw new Error("Abre una secuencia.");
        out.push("Secuencia: " + seq.name);
        dump("Sequence", seq);
        dump("Track de video", seq.videoTracks[0]);
        if (seq.videoTracks[0].clips.numItems) dump("TrackItem", seq.videoTracks[0].clips[0]);
        app.enableQE();
        var qseq = qe.project.getActiveSequence();
        dump("QE Sequence", qseq);
        dump("QE Track de audio", qseq.getAudioTrackAt(0));
        dump("QE Track de video", qseq.getVideoTrackAt(0));
        dump("QE Project", qe.project);
    } catch (error) { out.push("ERROR: " + error); }
    var f = new File(File($.fileName).parent.fsName + "/Diagnostico_API_Premiere.txt");
    f.encoding = "UTF-8";
    if (f.open("w")) { f.write(out.join("\n")); f.close(); }
    alert("Diagnostico guardado. No se modifico nada.\n" + f.fsName);
})();
