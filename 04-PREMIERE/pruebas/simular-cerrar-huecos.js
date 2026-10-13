// Prueba de PPRO-02-CERRAR-HUECOS-SIN-VIDEO.jsx fuera de Premiere:  node simular-cerrar-huecos.js
//
// Sustituye a Premiere por un modelo hecho con lo que mostraron las ejecuciones reales:
//  - setInPoint/setOutPoint pasan los segundos a ticks truncando;
//  - extract() corta el video en el fotograma que contiene cada marca (hacia abajo)
//    y el audio en el tick exacto;
//  - un tramo que queda vacio al ajustarlo a fotogramas no hace nada.
// Los numeros de la secuencia de prueba salen de un informe real, incluido el fallo
// que se comia un fotograma cuando las marcas se pedian en el segundo "exacto".
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");
const SCRIPT = process.argv[2] || path.join(__dirname, "..", "PPRO-02-CERRAR-HUECOS-SIN-VIDEO.jsx");
const TPS = 254016000000, FPS = 30, FT = TPS / FPS;

function Time() { this.ticks = "0"; }
Object.defineProperty(Time.prototype, "seconds", { get() { return Number(this.ticks) / TPS; } });
Time.prototype.getFormatted = function () { return "F" + Math.round(Number(this.ticks) / FT); };

function makeTimeline({ video, audio }) {
    const mk = (spans) => spans.map(([s, e]) => ({ s: Math.round(s * FT), e: Math.round(e * FT) }));   // en ticks
    return { video: video.map(mk), audio: audio.map(mk), inT: 0, outT: 0, undo: [] };
}
function premiere(tl, opts = {}) {
    const trackApi = (list) => ({
        isLocked: () => false, setTargeted() {},
        get clips() {
            const sorted = list.slice().sort((a, b) => a.s - b.s);
            return new Proxy({}, { get: (_t, k) => (k === "numItems" ? sorted.length
                : { start: { ticks: String(sorted[Number(k)].s) }, end: { ticks: String(sorted[Number(k)].e) } }) });
        },
    });
    const trackList = (kind) => new Proxy({}, { get: (_t, k) => (k === "numTracks" ? tl[kind].length : trackApi(tl[kind][Number(k)])) });
    const seq = {
        name: "Prueba", sequenceID: "seq-1", timebase: String(FT), videoDisplayFormat: 104, zeroPoint: "0",
        getSettings: () => ({ videoFrameRate: { ticks: String(FT) }, videoDisplayFormat: 104 }),
        videoTracks: trackList("video"), audioTracks: trackList("audio"),
        setInPoint(sec) { tl.inT = Math.floor(sec * TPS); },
        setOutPoint(sec) { tl.outT = Math.floor(sec * TPS); },
        getInPointAsTime: () => ({ ticks: String(tl.inT) }),
        getOutPointAsTime: () => ({ ticks: String(tl.outT) }),
    };
    function cut(list, a, b, shift) {
        const out = [];
        for (const c of list) {
            if (c.e <= a) out.push(c);
            else if (c.s >= b) out.push({ s: c.s - shift, e: c.e - shift });
            else {
                if (c.s < a) out.push({ s: c.s, e: a });
                if (c.e > b) out.push({ s: b - shift, e: c.e - shift });
            }
        }
        return out;
    }
    function extract() {
        const a = Math.floor(tl.inT / FT) * FT, b = Math.floor(tl.outT / FT) * FT;
        if (b <= a) return;                                   // vacio al ajustarlo a fotogramas
        if (opts.oneFrameNoOp && b - a <= FT) return;
        tl.undo.push(JSON.stringify({ video: tl.video, audio: tl.audio }));
        const frames = Math.round((tl.outT - tl.inT) / FT) * FT;
        tl.video = tl.video.map((list) => cut(list, a, b, frames));
        tl.audio = tl.audio.map((list, i) => (i === opts.unsyncedAudio ? list : cut(list, tl.inT, tl.outT, tl.outT - tl.inT)));
    }
    const qtrack = { isSyncLocked: () => true, setSyncLock() {} };
    const qe = { project: {
        getActiveSequence: () => ({ extract, numVideoTracks: tl.video.length, numAudioTracks: tl.audio.length,
            getVideoTrackAt: () => qtrack, getAudioTrackAt: () => qtrack }),
        undo() { const saved = JSON.parse(tl.undo.pop()); tl.video = saved.video; tl.audio = saved.audio; },
    } };
    return { seq, qe, extract };
}
function runScript(tl, opts) {
    const { seq, qe } = premiere(tl, opts);
    const messages = [];
    function File(target) { this.fsName = String(target.fsName || target); this.parent = { fsName: "X:/tmp" }; }
    File.prototype.open = () => true; File.prototype.write = function (text) { File.last = text; }; File.prototype.close = () => {};
    const sandbox = { app: { project: { activeSequence: seq }, enableQE() {} }, qe, Time, File, $: { fileName: "X:/tmp/s.jsx" },
        alert: (m) => messages.push(m),
        prompt: () => { throw new Error("el script no debe preguntar nada"); },
        confirm: () => { throw new Error("el script no debe preguntar nada"); } };
    vm.runInContext(fs.readFileSync(SCRIPT, "utf8"), vm.createContext(sandbox));
    return { message: messages[messages.length - 1], log: File.last };
}
const frames = (list) => list.slice().sort((a, b) => a.s - b.s).map((c) => [c.s / FT, c.e / FT]);
const total = (list) => list.reduce((sum, c) => sum + (c.e - c.s), 0) / FT;
const continuous = (tl) => {
    const all = [].concat(...tl.video).sort((a, b) => a.s - b.s);
    let cursor = 0;
    for (const c of all) { if (c.s > cursor) return false; cursor = Math.max(cursor, c.e); }
    return cursor;
};

// La secuencia real segun los informes: estas tomas suman los 28869 fotogramas de video que dio Premiere.
const takes = [[330, 6580], [6868, 16393], [18373, 27135], [27643, 28481], [29720, 32088], [32925, 34051]];
const real = (micEnd = 34572) => makeTimeline({
    video: [takes, [[400, 6000], [7000, 16393], [18373, 20000], [29800, 32088], [33000, 34000]]],
    audio: [takes, [[400, 6000], [7000, 16393], [18373, 20000], [29800, 32088], [33000, 34000]], [[0, micEnd]]],
});
assert.strictEqual(total(real().video[0]), 28869);

// 1. El modelo reproduce el dano visto en Premiere al pedir las marcas en el segundo exacto.
let tl = real();
let pp = premiere(tl);
pp.seq.setInPoint(34051 * FT / TPS); pp.seq.setOutPoint(34572 * FT / TPS); pp.extract();     // la cola: limpia, como se vio
assert.strictEqual(total(tl.video[0]), 28869);
pp.seq.setInPoint(32088 * FT / TPS); pp.seq.setOutPoint(32925 * FT / TPS); pp.extract();     // la ejecucion que fallo
assert.strictEqual(total(tl.video[0]), 28868);                                                // un fotograma de video perdido
assert.deepStrictEqual(frames(tl.video[0]).slice(4), [[29720, 32087], [32088, 33214]]);       // y un hueco de un fotograma
assert.strictEqual(Math.round(tl.audio[2][tl.audio[2].length - 1].e / FT), 33214);            // "fin 33214"
const damaged = JSON.stringify(tl);
pp.seq.setInPoint(32087 * FT / TPS); pp.seq.setOutPoint(32088 * FT / TPS); pp.extract();     // ultima ejecucion: no paso nada
assert.strictEqual(JSON.stringify([tl.video, tl.audio]), JSON.stringify([JSON.parse(damaged).video, JSON.parse(damaged).audio]));

// 2. El script sobre una copia limpia: todos los huecos cerrados de una vez, sin perder video y con el audio a la par.
tl = real();
let r = runScript(tl);
assert.ok(/cerrados: 7 de 7/.test(r.message), r.message);
assert.strictEqual(continuous(tl), 28869 * FT);
assert.strictEqual(total(tl.video[0]), 28869);
assert.deepStrictEqual(frames(tl.audio[0]), frames(tl.video[0]));
assert.deepStrictEqual(frames(tl.audio[1]), frames(tl.video[1]));
assert.strictEqual(Math.round(total(tl.audio[2])), 28869);
assert.deepStrictEqual(frames(tl.audio[2]).map(([s, e]) => [Math.round(s), Math.round(e)]),
    [[0, 6250], [6250, 15775], [15775, 24537], [24537, 25375], [25375, 27743], [27743, 28869]]);

// 3. El script sobre la secuencia ya danada (cola cerrada, un fotograma perdido y un hueco de un fotograma).
tl = JSON.parse(damaged); tl.undo = [];
r = runScript(tl);
assert.ok(/cerrados: 6 de 6/.test(r.message), r.message);
assert.strictEqual(continuous(tl), 28868 * FT);
assert.strictEqual(total(tl.video[0]), 28868);

// 4. Si Premiere se niega a extraer un tramo de un fotograma, ese se deja y los demas se cierran.
tl = JSON.parse(damaged); tl.undo = [];
r = runScript(tl, { oneFrameNoOp: true });
assert.ok(/cerrados: 5 de 6/.test(r.message) && /no extrajo 1 tramo/.test(r.message), r.message);
assert.strictEqual(total(tl.video[0]), 28868);
assert.deepStrictEqual(frames(tl.video[0]).slice(4), [[25375, 27742], [27743, 28869]]);

// 5. Una pista que no sigue al resto se detecta en la primera extraccion que la afecta y se deshace.
tl = real();
const tailClosed = real(34051);   // la cola solo tiene audio y nada que desfasar: esa se cierra antes
r = runScript(tl, { unsyncedAudio: 1 });
assert.ok(/no quedo como debia/.test(r.message) && /se deshizo solo/.test(r.message) && /antes: 1\./.test(r.message), r.message);
assert.strictEqual(JSON.stringify([tl.video, tl.audio]), JSON.stringify([tailClosed.video, tailClosed.audio]));

// 6. Microfono que termina a mitad de un fotograma: la cola se quita entera.
tl = real(34572.4);
r = runScript(tl);
assert.ok(/cerrados: 7 de 7/.test(r.message), r.message);
assert.strictEqual(Math.round(total(tl.audio[2])), 28869);

// 7. Nada que hacer.
tl = makeTimeline({ video: [[[0, 300], [300, 600]]], audio: [[[0, 600]]] });
r = runScript(tl);
assert.ok(/ya es continua/.test(r.message));
console.log("Cerrar huecos sin video: todas las pruebas pasan");
