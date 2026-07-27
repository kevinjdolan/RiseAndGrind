/*
 * Batch background removal for the Chad reference renders, via Photoshop's
 * Select Subject engine.
 *
 * Procedure (established 2026-07-26):
 *   unlock Background layer -> Select Subject ("autoCutout")
 *   -> apply selection as a Reveal Selection layer mask
 *   -> save PNG (the composite honours the mask, so the background becomes alpha)
 *
 * The canvas is deliberately left at the source size. Every existing
 * <name>.png in scratch_data/chad_model_3 matches its <name>.jpeg pixel
 * dimensions because of this. Create /tmp/ps_bg_trim.txt to additionally crop
 * to the subject's bounding box.
 *
 * Build-specific notes (Photoshop Beta / 2026):
 *   - stringIDToTypeID("selectSubject") is NOT available and throws
 *     "The command <unknown> is not currently available".
 *     The working ID is "autoCutout".
 *   - stringIDToTypeID("removeBackground") also exists and produces the same
 *     matte, but it masks the layer directly and gives you no selection to
 *     inspect, so this script uses autoCutout.
 *   - charIDToTypeID("Mk  ") (two trailing spaces) creates the mask channel.
 *
 * I/O: reads newline-separated absolute paths from /tmp/ps_bg_inputs.txt,
 * writes <same-dir>/<basename>.png, appends one status line per file to
 * /tmp/ps_bg_result.txt.
 */

#target photoshop

var INPUTS = "/tmp/ps_bg_inputs.txt";
var RESULT = "/tmp/ps_bg_result.txt";
var TRIM = new File("/tmp/ps_bg_trim.txt").exists;

function readLines(path) {
    var f = new File(path);
    f.open("r");
    var body = f.read();
    f.close();
    var raw = body.split("\n");
    var out = [];
    for (var i = 0; i < raw.length; i++) {
        var t = raw[i].replace(/^\s+|\s+$/g, "");
        if (t.length) out.push(t);
    }
    return out;
}

function log(line) {
    var f = new File(RESULT);
    f.open("a");
    f.writeln(line);
    f.close();
}

function hasSelection(doc) {
    try {
        var b = doc.selection.bounds;
        return true;
    } catch (e) {
        return false;
    }
}

// A locked Background layer cannot carry a mask; convert it to a normal layer.
function unlockBackground(doc) {
    try {
        if (!doc.activeLayer.isBackgroundLayer) return;
        var desc = new ActionDescriptor();
        var ref = new ActionReference();
        ref.putProperty(charIDToTypeID("Prpr"), charIDToTypeID("Bckg"));
        ref.putEnumerated(charIDToTypeID("Lyr "), charIDToTypeID("Ordn"), charIDToTypeID("Bckg"));
        desc.putReference(charIDToTypeID("null"), ref);
        var lyrDesc = new ActionDescriptor();
        lyrDesc.putString(charIDToTypeID("Nm  "), "Layer 0");
        lyrDesc.putEnumerated(charIDToTypeID("Md  "), charIDToTypeID("BlnM"), charIDToTypeID("Nrml"));
        lyrDesc.putUnitDouble(charIDToTypeID("Opct"), charIDToTypeID("#Prc"), 100);
        desc.putObject(charIDToTypeID("T   "), charIDToTypeID("Lyr "), lyrDesc);
        executeAction(charIDToTypeID("setd"), desc, DialogModes.NO);
    } catch (e) {}
}

// Select Subject — the engine behind the Remove Background quick action.
function selectSubject() {
    var desc = new ActionDescriptor();
    desc.putBoolean(stringIDToTypeID("sampleAllLayers"), false);
    executeAction(stringIDToTypeID("autoCutout"), desc, DialogModes.NO);
}

// Turn the live selection into a layer mask (Reveal Selection).
function maskFromSelection() {
    var desc = new ActionDescriptor();
    desc.putClass(charIDToTypeID("Nw  "), charIDToTypeID("Chnl"));
    var ref = new ActionReference();
    ref.putEnumerated(charIDToTypeID("Chnl"), charIDToTypeID("Chnl"), charIDToTypeID("Msk "));
    desc.putReference(charIDToTypeID("At  "), ref);
    desc.putEnumerated(charIDToTypeID("Usng"), stringIDToTypeID("userMaskEnabled"), charIDToTypeID("RvlS"));
    executeAction(charIDToTypeID("Mk  "), desc, DialogModes.NO);
}

function removeBg(inPath, outPath) {
    var doc = app.open(new File(inPath));

    unlockBackground(doc);
    selectSubject();

    if (!hasSelection(doc)) {
        doc.close(SaveOptions.DONOTSAVECHANGES);
        throw new Error("no selection from Select Subject");
    }

    maskFromSelection();

    if (TRIM) doc.trim(TrimType.TRANSPARENT);

    var pngOpts = new PNGSaveOptions();
    pngOpts.compression = 6;
    pngOpts.interlaced = false;
    doc.saveAs(new File(outPath), pngOpts, true, Extension.LOWERCASE);

    var dims = doc.width.as("px") + "x" + doc.height.as("px");
    doc.close(SaveOptions.DONOTSAVECHANGES);
    return dims;
}

// Close anything a previous failed run left open, without saving.
while (app.documents.length > 0) {
    app.activeDocument.close(SaveOptions.DONOTSAVECHANGES);
}

var inputs = readLines(INPUTS);
var prevDialogs = app.displayDialogs;
var prevUnits = app.preferences.rulerUnits;
app.displayDialogs = DialogModes.NO;
app.preferences.rulerUnits = Units.PIXELS;

for (var i = 0; i < inputs.length; i++) {
    var inPath = inputs[i];
    var outPath = inPath.replace(/\.[^.\/]+$/, "") + ".png";
    try {
        var dims = removeBg(inPath, outPath);
        log("OK\t" + outPath + "\t" + dims + (TRIM ? "\ttrimmed" : ""));
    } catch (e) {
        log("FAIL\t" + inPath + "\t" + e);
        try { app.activeDocument.close(SaveOptions.DONOTSAVECHANGES); } catch (e2) {}
    }
}

app.displayDialogs = prevDialogs;
app.preferences.rulerUnits = prevUnits;
"done";
