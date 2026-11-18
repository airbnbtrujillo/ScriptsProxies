/* DJI SBS: ejecutar en Premiere sobre una copia guardada del proyecto. */
(function () {
    var log = ['DJI SBS - ' + new Date()], plans = [], changed = {}, skipped = 0, errors = 0, proxies = 0, scales = 0;
    function norm(s) { return String(s || '').replace(/\\/g, '/').toLowerCase(); }
    function basename(s) { return String(s || '').replace(/\\/g, '/').split('/').pop(); }
    function report() {
        var f = new File(File($.fileName).parent.fsName + '/Informe_DJI_SBS_Premiere.txt');
        f.encoding = 'UTF-8';
        if (f.open('w')) { f.write(log.join('\n')); f.close(); return f.fsName; }
        return 'No se pudo guardar el informe junto al script';
    }
    function collect(bin, projectFolder) {
        var children = bin.children, i, item, path, match, original, proxy, folder, sourceParent;
        if (!children) return;
        for (i = 0; i < children.numItems; i++) {
            item = children[i];
            if (item.type === ProjectItemType.BIN) { collect(item, projectFolder); continue; }
            try { path = item.getMediaPath(); } catch (e) { continue; }
            match = /^(CAM_\d{14}_\d{4}_D_SBS)(?:_Proxy)?\.mp4$/i.exec(basename(path));
            if (!match) continue;
            // La carpeta CAM_001 esta junto al archivo .prproj.
            // Si el proyecto fue trasladado, se usa la estructura del medio actual.
            folder = new Folder(projectFolder.fsName + '/CAM_001');
            if (!folder.exists) {
                sourceParent = new File(path).parent;
                if (String(sourceParent.name).toLowerCase() === 'proxy dji osmo vr180') sourceParent = sourceParent.parent;
                if (String(sourceParent.name).toLowerCase() === 'cam_001') folder = sourceParent;
            }
            original = new File(folder.fsName + '/' + match[1] + '.mp4');
            proxy = new File(folder.fsName + '/Proxy DJI OSMO VR180/' + match[1] + '_Proxy.mp4');
            if (!original.exists || !proxy.exists) {
                skipped++; log.push('OMITIDO: ' + path + ' | original: ' + original.fsName + ' existe=' + original.exists + ' | proxy: ' + proxy.fsName + ' existe=' + proxy.exists); continue;
            }
            plans.push({ item: item, before: path, original: original, proxy: proxy });
            log.push('PLAN: ' + path + ' -> ' + original.fsName + ' | proxy: ' + proxy.fsName);
        }
    }
    function adjust(clip, seq, track) {
        try {
            var comps = clip.components, i, j, comp, prop, name, old;
            for (i = 0; i < comps.numItems; i++) {
                comp = comps[i];
                if (String(comp.matchName) !== 'AE.ADBE Motion') continue;
                for (j = 0; j < comp.properties.numItems; j++) {
                    prop = comp.properties[j]; name = String(prop.displayName).toLowerCase();
                    if (name !== 'scale' && name !== 'escala') continue;
                    if (prop.isTimeVarying()) { skipped++; log.push('ESCALA ANIMADA OMITIDA: ' + seq.name + ' / ' + clip.name + ' / pista ' + track); return; }
                    old = prop.getValue();
                    if (typeof old !== 'number') throw new Error('Escala no numerica');
                    prop.setValue(100, 1);
                    if (Math.abs(Number(prop.getValue()) - 100) > 0.001) throw new Error('Premiere no confirmo escala 100');
                    scales++; log.push('ESCALA 100: ' + seq.name + ' / ' + clip.name + ' / pista ' + track + ' (antes ' + old + ')'); return;
                }
            }
            throw new Error('No se encontro Movimiento > Escala');
        } catch (e) { errors++; log.push('ERROR ESCALA: ' + seq.name + ' / ' + clip.name + ': ' + e); }
    }
    try {
        if (!app.project || !app.project.rootItem) throw new Error('Abre el proyecto en Premiere');
        if (!app.project.path) throw new Error('Guarda primero el proyecto para localizar CAM_001');
        var projectFolder = new File(app.project.path).parent;
        log.push('Proyecto: ' + app.project.name + ' | carpeta: ' + projectFolder.fsName);
        collect(app.project.rootItem, projectFolder);
        log.push('BUSQUEDA COMPLETA: ' + plans.length + ' parejas encontradas');
        if (!plans.length) { alert('No se encontraron parejas aplicables. Informe: ' + report()); return; }
        if (!confirm('Se encontraron ' + plans.length + ' elementos. Se vincularan los SBS y proxies y se pondra Escala a 100 en todas las secuencias. Las escalas animadas se conservan.\n\nGuarda antes una copia del proyecto. ¿Continuar?', false, 'Vincular DJI SBS')) { log.push('Cancelado sin cambios'); report(); return; }
        var i, item, plan, result;
        for (i = 0; i < plans.length; i++) {
            plan = plans[i]; item = plan.item;
            try {
                if (norm(plan.before) !== norm(plan.original.fsName)) {
                    if (!item.canChangeMediaPath()) throw new Error('Premiere no permite cambiar este medio');
                    result = item.changeMediaPath(plan.original.fsName, false);
                    if (norm(item.getMediaPath()) !== norm(plan.original.fsName)) throw new Error('Reemplazo no confirmado. Codigo: ' + result);
                }
                changed[String(item.nodeId)] = true;
                item.name = plan.original.name;
                log.push('ORIGINAL OK: ' + item.name);
                if (!item.canProxy()) throw new Error('Premiere no permite adjuntar proxy');
                result = item.attachProxy(plan.proxy.fsName, 0);
                if (result !== 0) throw new Error('No se adjunto el proxy. Codigo: ' + result);
                proxies++; log.push('PROXY OK: ' + plan.proxy.fsName);
            } catch (e) { errors++; log.push('ERROR: ' + plan.before + ' | ' + e); }
        }
        var seqs = app.project.sequences, s, t, j, seq, tracks, clips, clip;
        for (s = 0; s < seqs.numSequences; s++) {
            seq = seqs[s]; tracks = seq.videoTracks;
            for (t = 0; t < tracks.numTracks; t++) {
                clips = tracks[t].clips;
                for (j = 0; j < clips.numItems; j++) {
                    clip = clips[j];
                    try { if (clip.projectItem && changed[String(clip.projectItem.nodeId)]) adjust(clip, seq, t + 1); }
                    catch (ex) { errors++; log.push('ERROR CLIP: ' + seq.name + ' | ' + ex); }
                }
            }
        }
        log.push('RESUMEN: proxies=' + proxies + ', escalas=' + scales + ', omitidos=' + skipped + ', errores=' + errors);
        alert('Terminado.\nProxies: ' + proxies + '\nEscalas a 100: ' + scales + '\nOmitidos: ' + skipped + '\nErrores: ' + errors + '\nInforme: ' + report());
    } catch (e) { log.push('ERROR GENERAL: ' + e + ' | linea: ' + e.line); alert('No se pudo completar: ' + e + '\nInforme: ' + report()); }
})();
