package com.geskoide;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ContentResolver;
import android.content.Intent;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.text.Editable;
import android.text.Spannable;
import android.text.TextWatcher;
import android.text.style.ForegroundColorSpan;
import android.view.Gravity;
import android.view.MenuItem;
import android.view.MotionEvent;
import android.view.View;
import android.view.inputmethod.InputMethodManager;
import android.content.Context;
import android.widget.Button;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class MainActivity extends Activity {
    private static final int REQ_OPEN = 20;
    private static final int REQ_SAVE_AS = 21;

    private static final int BG = Color.rgb(15, 21, 18);
    private static final int PANEL = Color.rgb(19, 27, 23);
    private static final int EDITOR_BG = Color.rgb(14, 20, 17);
    private static final int GUTTER_BG = Color.rgb(12, 17, 15);
    private static final int STATUS_BG = Color.rgb(24, 35, 29);
    private static final int BORDER = Color.rgb(35, 49, 41);
    private static final int FG = Color.rgb(215, 227, 219);
    private static final int DIM = Color.rgb(127, 145, 135);
    private static final int FAINT = Color.rgb(84, 101, 92);
    private static final int ACCENT = Color.rgb(63, 214, 143);
    private static final int ACCENT_DARK = Color.rgb(42, 148, 99);
    private static final int CURRENT_LINE = Color.rgb(21, 31, 25);
    private static final int ERROR = Color.rgb(255, 107, 107);
    private static final int WARN = Color.rgb(255, 200, 87);
    private static final int INFO = Color.rgb(111, 183, 255);

    private static final int KW = Color.rgb(69, 211, 138);
    private static final int BUILTIN = Color.rgb(108, 184, 232);
    private static final int STRING = Color.rgb(230, 160, 108);
    private static final int NUMBER = Color.rgb(217, 159, 232);
    private static final int COMMENT = Color.rgb(95, 117, 102);
    private static final int OP = Color.rgb(127, 216, 192);
    private static final int BRACKET = Color.rgb(224, 180, 88);

    private final List<Language> languages = new ArrayList<>();
    private final Map<String, Language> languagesById = new LinkedHashMap<>();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private CodeEditor editor;
    private TextView status;
    private TextView output;
    private TextView pathLabel;
    private WebView runnerWebView;
    private Uri currentUri;
    private String currentName = "untitled.py";
    private Language currentLanguage;
    private int pendingStaticIssues;
    private int pendingRuntimeIssues;
    private boolean runningDebug;
    private boolean dirty;
    private boolean highlighting;

    private final Runnable highlightRunnable = new Runnable() {
        @Override
        public void run() {
            highlight();
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        loadLanguages();
        buildUi();
        loadInitialDocument();
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BG);
        setContentView(root);

        LinearLayout titleBar = new LinearLayout(this);
        titleBar.setOrientation(LinearLayout.VERTICAL);
        titleBar.setPadding(dp(14), dp(12), dp(14), dp(8));
        titleBar.setBackgroundColor(PANEL);
        root.addView(titleBar, new LinearLayout.LayoutParams(-1, -2));

        TextView title = new TextView(this);
        title.setText("GeskoIDE");
        title.setTextColor(FG);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextSize(22);
        titleBar.addView(title);

        pathLabel = new TextView(this);
        pathLabel.setTextColor(DIM);
        pathLabel.setTextSize(12);
        pathLabel.setSingleLine(true);
        titleBar.addView(pathLabel);

        HorizontalScrollView toolsScroller = new HorizontalScrollView(this);
        toolsScroller.setHorizontalScrollBarEnabled(false);
        toolsScroller.setBackgroundColor(PANEL);
        root.addView(toolsScroller, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout tools = new LinearLayout(this);
        tools.setOrientation(LinearLayout.HORIZONTAL);
        tools.setPadding(dp(10), dp(0), dp(10), dp(10));
        toolsScroller.addView(tools);

        addButton(tools, "New", new View.OnClickListener() {
            @Override public void onClick(View v) { showTemplateMenu(v); }
        });
        addButton(tools, "Lang", new View.OnClickListener() {
            @Override public void onClick(View v) { showLanguageMenu(v); }
        });
        addButton(tools, "Open", new View.OnClickListener() {
            @Override public void onClick(View v) { openDocument(); }
        });
        addButton(tools, "Save", new View.OnClickListener() {
            @Override public void onClick(View v) { saveDocument(); }
        });
        addButton(tools, "Save As", new View.OnClickListener() {
            @Override public void onClick(View v) { saveAs(); }
        });
        addButton(tools, "Fix", new View.OnClickListener() {
            @Override public void onClick(View v) { quickFix(); }
        });
        addButton(tools, "Check", new View.OnClickListener() {
            @Override public void onClick(View v) { runChecks(); }
        });
        addButton(tools, "Run", new View.OnClickListener() {
            @Override public void onClick(View v) { runActive(); }
        });
        addButton(tools, "Debug", new View.OnClickListener() {
            @Override public void onClick(View v) { debugActive(); }
        });

        editor = new CodeEditor(this);
        editor.setTextSize(15);
        editor.setTextColor(FG);
        editor.setHintTextColor(FAINT);
        editor.setGravity(Gravity.TOP | Gravity.START);
        editor.setTypeface(Typeface.MONOSPACE);
        editor.setBackgroundColor(EDITOR_BG);
        editor.setHorizontallyScrolling(true);
        editor.setSingleLine(false);
        editor.setMinLines(18);
        editor.setInputType(android.text.InputType.TYPE_CLASS_TEXT
                | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
                | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        editor.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {}
            @Override public void afterTextChanged(Editable s) {
                if (!highlighting) {
                    dirty = true;
                    updateStatus("Editing", INFO);
                    handler.removeCallbacks(highlightRunnable);
                    handler.postDelayed(highlightRunnable, 160);
                }
            }
        });

        root.addView(editor, new LinearLayout.LayoutParams(-1, 0, 1f));

        ScrollView outputScroll = new ScrollView(this);
        outputScroll.setBackgroundColor(PANEL);
        output = new TextView(this);
        output.setTextColor(DIM);
        output.setTypeface(Typeface.MONOSPACE);
        output.setTextSize(12);
        output.setPadding(dp(12), dp(8), dp(12), dp(8));
        outputScroll.addView(output, new ScrollView.LayoutParams(-1, -2));
        root.addView(outputScroll, new LinearLayout.LayoutParams(-1, dp(112)));

        status = new TextView(this);
        status.setTextColor(DIM);
        status.setTextSize(12);
        status.setSingleLine(true);
        status.setPadding(dp(12), dp(7), dp(12), dp(7));
        status.setBackgroundColor(STATUS_BG);
        root.addView(status, new LinearLayout.LayoutParams(-1, -2));
    }

    private void addButton(LinearLayout parent, String label, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setText(label);
        b.setTextColor(FG);
        b.setTextSize(13);
        b.setPadding(dp(12), 0, dp(12), 0);
        b.setMinHeight(dp(40));
        b.setMinWidth(dp(72));
        b.setBackground(buttonBg());
        b.setOnClickListener(listener);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, dp(40));
        lp.setMargins(0, 0, dp(8), 0);
        parent.addView(b, lp);
    }

    private GradientDrawable buttonBg() {
        GradientDrawable g = new GradientDrawable();
        g.setColor(Color.rgb(29, 42, 35));
        g.setCornerRadius(dp(6));
        g.setStroke(dp(1), BORDER);
        return g;
    }

    private void loadInitialDocument() {
        Intent intent = getIntent();
        if (intent != null && intent.getData() != null) {
            readUri(intent.getData());
            return;
        }
        setDocument("untitled.py",
                languageById("python").skeleton);
        dirty = false;
        updateStatus("Ready", ACCENT);
        output.setText("GeskoIDE Android Edition\n"
                + languages.size() + " languages loaded from the original app.\n"
                + "Run works offline for Python, Go, JavaScript, basic TypeScript, SQL, Shell, HTML, CSS, Markdown, and JSON.\n"
                + "Check and Debug now run diagnostics for every language template.");
    }

    private void showTemplateMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        for (int i = 0; i < languages.size(); i++) {
            Language lang = languages.get(i);
            menu.getMenu().add(0, i, i, lang.name + " (" + lang.defaultExt() + ")");
        }
        menu.setOnMenuItemClickListener(new PopupMenu.OnMenuItemClickListener() {
            @Override public boolean onMenuItemClick(MenuItem item) {
                Language lang = languages.get(item.getItemId());
                currentLanguage = lang;
                setDocument("untitled" + lang.defaultExt(), lang.skeleton);
                currentUri = null;
                dirty = false;
                output.setText("");
                updateStatus("New " + lang.name, ACCENT);
                showKeyboard();
                return true;
            }
        });
        menu.show();
    }

    private void showLanguageMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        for (int i = 0; i < languages.size(); i++) {
            Language lang = languages.get(i);
            menu.getMenu().add(0, i, i, lang.name + " (" + lang.defaultExt() + ")");
        }
        menu.setOnMenuItemClickListener(new PopupMenu.OnMenuItemClickListener() {
            @Override public boolean onMenuItemClick(MenuItem item) {
                currentLanguage = languages.get(item.getItemId());
                if (currentName != null && currentName.startsWith("untitled.")) {
                    currentName = "untitled" + currentLanguage.defaultExt();
                }
                highlight();
                updateStatus(currentLanguage.name, ACCENT);
                output.setText("Language set to " + currentLanguage.name + ".");
                return true;
            }
        });
        menu.show();
    }

    private void openDocument() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        String[] mimes = {"text/*", "application/json", "application/javascript", "application/xml"};
        intent.putExtra(Intent.EXTRA_MIME_TYPES, mimes);
        startActivityForResult(intent, REQ_OPEN);
    }

    private void saveDocument() {
        if (currentUri == null) {
            saveAs();
        } else {
            writeUri(currentUri);
        }
    }

    private void saveAs() {
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("text/plain");
        intent.putExtra(Intent.EXTRA_TITLE, currentName == null ? "untitled.txt" : currentName);
        startActivityForResult(intent, REQ_SAVE_AS);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (resultCode != RESULT_OK || data == null || data.getData() == null) {
            return;
        }
        Uri uri = data.getData();
        try {
            getContentResolver().takePersistableUriPermission(uri,
                    data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION));
        } catch (Exception ignored) {
        }
        if (requestCode == REQ_OPEN) {
            readUri(uri);
        } else if (requestCode == REQ_SAVE_AS) {
            currentUri = uri;
            currentName = displayName(uri);
            writeUri(uri);
        }
    }

    private void readUri(Uri uri) {
        try {
            ContentResolver resolver = getContentResolver();
            InputStream in = resolver.openInputStream(uri);
            if (in == null) throw new IllegalStateException("No input stream");
            BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append('\n');
            }
            reader.close();
            currentUri = uri;
            setDocument(displayName(uri), sb.toString());
            dirty = false;
            output.setText("");
            updateStatus("Opened", ACCENT);
        } catch (Exception ex) {
            showError("Could not open file", ex);
        }
    }

    private void writeUri(Uri uri) {
        try {
            OutputStream out = getContentResolver().openOutputStream(uri, "wt");
            if (out == null) throw new IllegalStateException("No output stream");
            out.write(editor.getText().toString().getBytes(StandardCharsets.UTF_8));
            out.close();
            dirty = false;
            updatePathLabel();
            updateStatus("Saved", ACCENT);
            Toast.makeText(this, "Saved", Toast.LENGTH_SHORT).show();
        } catch (Exception ex) {
            showError("Could not save file", ex);
        }
    }

    private void setDocument(String name, String text) {
        currentName = name;
        currentLanguage = detectLanguage(name);
        highlighting = true;
        editor.setText(text);
        int marker = text.indexOf("\u00ab\u00bb");
        if (marker >= 0) {
            editor.setSelection(marker, marker + 2);
        } else {
            editor.setSelection(Math.min(editor.length(), Math.max(0, text.indexOf("\n") + 1)));
        }
        highlighting = false;
        updatePathLabel();
        highlight();
    }

    private String displayName(Uri uri) {
        String result = null;
        if ("content".equals(uri.getScheme())) {
            Cursor cursor = null;
            try {
                cursor = getContentResolver().query(uri, null, null, null, null);
                if (cursor != null && cursor.moveToFirst()) {
                    int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                    if (idx >= 0) result = cursor.getString(idx);
                }
            } finally {
                if (cursor != null) cursor.close();
            }
        }
        if (result == null) {
            String path = uri.getPath();
            int slash = path == null ? -1 : path.lastIndexOf('/');
            result = slash >= 0 ? path.substring(slash + 1) : "document.txt";
        }
        return result;
    }

    private void runActive() {
        runActive(false);
    }

    private void debugActive() {
        runActive(true);
    }

    private void runActive(boolean debug) {
        if (currentLanguage == null) currentLanguage = detectLanguage(currentName);
        String id = currentLanguage.id;
        String text = editor.getText().toString();
        output.setText("");
        runningDebug = debug;
        updateStatus(debug ? "Debugging" : "Running", INFO);
        if (debug) {
            debugActiveLanguage(id, text);
            return;
        }
        if ("python".equals(id)) {
            runInWebRuntime("python", text);
        } else if ("go".equals(id)) {
            runInWebRuntime("go", text);
        } else if ("javascript".equals(id) || "typescript".equals(id)) {
            runInWebRuntime(id, text);
        } else if ("sql".equals(id)) {
            runSql(text);
        } else if ("shell".equals(id)) {
            runShell(text);
        } else if ("json".equals(id)) {
            runJson(text);
        } else if ("html".equals(id)) {
            showPreview("HTML Preview", text);
        } else if ("css".equals(id)) {
            showPreview("CSS Preview", "<!doctype html><html><head><style>" + escapeHtml(text)
                    + "</style></head><body><h1>GeskoIDE CSS Preview</h1><p>Edit CSS, then Run again.</p></body></html>");
        } else if ("markdown".equals(id)) {
            showPreview("Markdown Preview", markdownToHtml(text));
        } else {
            output.setText(buildStaticDebugReport(text, currentLanguage.name + " static run check"));
            appendOutput("info", "\nRun completed as a static check for " + currentLanguage.name
                    + ". Use Debug for the symbol trace and diagnostics view.\n");
            updateStatus("Static run check", INFO);
        }
    }

    private void debugActiveLanguage(String id, String text) {
        if ("python".equals(id)) {
            runInWebRuntime("python-debug", text);
        } else if ("javascript".equals(id) || "typescript".equals(id)) {
            runInWebRuntime(id + "-debug", text);
        } else if ("go".equals(id)) {
            output.setText(buildStaticDebugReport(text, "Go static trace before bundled Yaegi run"));
            runInWebRuntime("go-debug", text);
        } else if ("sql".equals(id)) {
            runSql(text, true);
        } else if ("shell".equals(id)) {
            runShell(text, true);
        } else {
            output.setText(buildStaticDebugReport(text, currentLanguage.name + " static debugger"));
            updateStatus("Static debug", INFO);
        }
    }

    private void runInWebRuntime(final String mode, final String code) {
        appendOutput("info", "$ " + (mode.endsWith("-debug") ? "debug " : "run ")
                + mode.replace("-debug", "") + " (bundled offline runtime)\n");
        runnerWebView = new WebView(this);
        WebSettings settings = runnerWebView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setAllowFileAccessFromFileURLs(true);
        settings.setAllowUniversalAccessFromFileURLs(true);
        runnerWebView.addJavascriptInterface(new RunnerBridge(), "AndroidRunner");
        runnerWebView.setWebViewClient(new WebViewClient() {
            @Override public void onPageFinished(WebView view, String url) {
                String quotedCode = JSONObject.quote(code);
                String js;
                if ("python".equals(mode)) {
                    js = "GeskoRunner.runPython(" + quotedCode + ")";
                } else if ("python-debug".equals(mode)) {
                    js = "GeskoRunner.debugPython(" + quotedCode + ")";
                } else if ("go".equals(mode)) {
                    js = "GeskoRunner.runGo(" + quotedCode + ")";
                } else if ("go-debug".equals(mode)) {
                    js = "GeskoRunner.runGo(" + quotedCode + ")";
                } else if ("javascript-debug".equals(mode) || "typescript-debug".equals(mode)) {
                    String base = mode.replace("-debug", "");
                    js = "GeskoRunner.debugJavaScript(" + quotedCode + "," + JSONObject.quote(base) + ")";
                } else {
                    js = "GeskoRunner.runJavaScript(" + quotedCode + "," + JSONObject.quote(mode) + ")";
                }
                view.evaluateJavascript(js, null);
            }
        });
        runnerWebView.loadUrl("file:///android_asset/runner.html");
    }

    private class RunnerBridge {
        @JavascriptInterface
        public void postMessage(String payload) {
            try {
                JSONObject obj = new JSONObject(payload);
                final String kind = obj.optString("kind", "out");
                final String message = obj.optString("message", "");
                handler.post(new Runnable() {
                    @Override public void run() {
                        if ("ready".equals(kind)) return;
                        if ("check-ok".equals(kind)) {
                            appendOutput("info", message);
                            return;
                        }
                        if ("check-err".equals(kind)) {
                            pendingRuntimeIssues++;
                            appendOutput("err", message);
                            return;
                        }
                        if ("check-done".equals(kind)) {
                            int total = pendingStaticIssues + pendingRuntimeIssues;
                            if (total == 0) {
                                appendOutput("info", "Runtime syntax passed.\n");
                            }
                            updateStatus(total == 0 ? "Clean" : total + " issue" + (total == 1 ? "" : "s"),
                                    total == 0 ? ACCENT : WARN);
                            return;
                        }
                        if ("debug".equals(kind)) {
                            appendOutput("info", message);
                            return;
                        }
                        if ("done".equals(kind)) {
                            String okText = runningDebug ? "Debug finished" : "Run finished";
                            String failText = runningDebug ? "Debug failed" : "Run failed";
                            updateStatus("0".equals(message) ? okText : failText,
                                    "0".equals(message) ? ACCENT : ERROR);
                        } else {
                            appendOutput(kind, message);
                        }
                    }
                });
            } catch (Exception ex) {
                handler.post(new Runnable() {
                    @Override public void run() {
                        appendOutput("err", "Runner bridge error\n");
                    }
                });
            }
        }
    }

    private void runJson(String text) {
        try {
            Object value = new JSONTokener(text).nextValue();
            String pretty = value instanceof JSONObject
                    ? ((JSONObject) value).toString(2)
                    : value instanceof JSONArray ? ((JSONArray) value).toString(2) : String.valueOf(value);
            output.setText(pretty + "\n");
            updateStatus("Valid JSON", ACCENT);
        } catch (Exception ex) {
            output.setText("Invalid JSON: " + ex.getMessage() + "\n");
            updateStatus("Invalid JSON", ERROR);
        }
    }

    private void runSql(final String text) {
        runSql(text, false);
    }

    private void runSql(final String text, final boolean debug) {
        output.setText("$ " + (debug ? "debug" : "run") + " sql (Android SQLite)\n");
        new Thread(new Runnable() {
            @Override public void run() {
                final StringBuilder result = new StringBuilder();
                boolean ok = true;
                SQLiteDatabase db = null;
                try {
                    db = SQLiteDatabase.create(null);
                    for (String stmt : splitSql(text)) {
                        String trimmed = stmt.trim();
                        if (trimmed.length() == 0) continue;
                        if (debug) {
                            result.append("[debug] statement: ").append(firstLine(trimmed)).append('\n');
                            if (isQuery(trimmed)) {
                                Cursor plan = db.rawQuery("EXPLAIN QUERY PLAN " + trimmed, null);
                                try {
                                    result.append("[debug] query plan\n");
                                    appendCursor(result, plan);
                                } finally {
                                    plan.close();
                                }
                            }
                        }
                        if (isQuery(trimmed)) {
                            Cursor c = db.rawQuery(trimmed, null);
                            try {
                                appendCursor(result, c);
                            } finally {
                                c.close();
                            }
                        } else {
                            db.execSQL(trimmed);
                            result.append("OK: ").append(firstLine(trimmed)).append('\n');
                        }
                    }
                } catch (Exception ex) {
                    ok = false;
                    result.append("SQL error: ").append(ex.getMessage()).append('\n');
                } finally {
                    if (db != null) db.close();
                }
                postRunResult(result.toString(), ok);
            }
        }).start();
    }

    private void runShell(final String text) {
        runShell(text, false);
    }

    private void runShell(final String text, final boolean debug) {
        output.setText("$ /system/bin/sh " + (debug ? "-x " : "") + "script\n");
        new Thread(new Runnable() {
            @Override public void run() {
                StringBuilder result = new StringBuilder();
                boolean ok = true;
                try {
                    File script = new File(getCacheDir(), "geskoide-run.sh");
                    FileOutputStream out = new FileOutputStream(script);
                    out.write(text.getBytes(StandardCharsets.UTF_8));
                    out.close();
                    ProcessBuilder builder = debug
                            ? new ProcessBuilder("/system/bin/sh", "-x", script.getAbsolutePath())
                            : new ProcessBuilder("/system/bin/sh", script.getAbsolutePath());
                    Process proc = builder.directory(getCacheDir()).redirectErrorStream(true).start();
                    ByteArrayOutputStream baos = new ByteArrayOutputStream();
                    InputStream in = proc.getInputStream();
                    long start = System.currentTimeMillis();
                    while (true) {
                        while (in.available() > 0) {
                            baos.write(in.read());
                        }
                        try {
                            int rc = proc.exitValue();
                            ok = rc == 0;
                            break;
                        } catch (IllegalThreadStateException running) {
                            if (System.currentTimeMillis() - start > 10000) {
                                proc.destroy();
                                ok = false;
                                result.append("Stopped after 10 seconds.\n");
                                break;
                            }
                            Thread.sleep(60);
                        }
                    }
                    result.append(new String(baos.toByteArray(), StandardCharsets.UTF_8));
                } catch (Exception ex) {
                    ok = false;
                    result.append("Shell error: ").append(ex.getMessage()).append('\n');
                }
                postRunResult(result.toString(), ok);
            }
        }).start();
    }

    private void postRunResult(final String text, final boolean ok) {
        handler.post(new Runnable() {
            @Override public void run() {
                appendOutput(ok ? "out" : "err", text.length() == 0 ? "(no output)\n" : text);
                updateStatus(ok ? "Run finished" : "Run failed", ok ? ACCENT : ERROR);
            }
        });
    }

    private void appendOutput(String kind, String text) {
        if (text == null || text.length() == 0) return;
        output.append(text);
        output.setTextColor("err".equals(kind) ? ERROR : "info".equals(kind) ? INFO : FG);
    }

    private void showPreview(String title, String html) {
        WebView preview = new WebView(this);
        preview.getSettings().setJavaScriptEnabled(true);
        preview.loadDataWithBaseURL("file:///android_asset/", html, "text/html", "UTF-8", null);
        new AlertDialog.Builder(this)
                .setTitle(title)
                .setView(preview)
                .setPositiveButton("Close", null)
                .show();
        output.setText("Preview rendered inside GeskoIDE.\n");
        updateStatus("Preview", ACCENT);
    }

    private List<String> splitSql(String text) {
        List<String> out = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        boolean single = false;
        boolean dbl = false;
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (ch == '\'' && !dbl) single = !single;
            if (ch == '"' && !single) dbl = !dbl;
            if (ch == ';' && !single && !dbl) {
                out.add(cur.toString());
                cur.setLength(0);
            } else {
                cur.append(ch);
            }
        }
        if (cur.length() > 0) out.add(cur.toString());
        return out;
    }

    private boolean isQuery(String sql) {
        String lower = sql.toLowerCase(Locale.US);
        return lower.startsWith("select") || lower.startsWith("pragma")
                || lower.startsWith("with") || lower.startsWith("explain");
    }

    private void appendCursor(StringBuilder out, Cursor c) {
        String[] cols = c.getColumnNames();
        for (String col : cols) out.append(col).append('\t');
        out.append('\n');
        int rows = 0;
        while (c.moveToNext() && rows < 200) {
            for (int i = 0; i < cols.length; i++) out.append(c.getString(i)).append('\t');
            out.append('\n');
            rows++;
        }
        if (rows == 200) out.append("... stopped at 200 rows\n");
        if (rows == 0) out.append("(no rows)\n");
    }

    private String firstLine(String text) {
        int n = text.indexOf('\n');
        String line = n >= 0 ? text.substring(0, n) : text;
        return line.length() > 80 ? line.substring(0, 80) + "..." : line;
    }

    private String markdownToHtml(String text) {
        StringBuilder html = new StringBuilder("<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>body{font-family:sans-serif;background:#0e1411;color:#d7e3db;padding:20px;line-height:1.55}code,pre{font-family:monospace;color:#e6a06c}a{color:#6fb7ff}h1,h2,h3{color:#3fd68f}</style></head><body>");
        String[] lines = text.split("\n", -1);
        boolean inList = false;
        for (String line : lines) {
            if (line.startsWith("# ")) {
                if (inList) { html.append("</ul>"); inList = false; }
                html.append("<h1>").append(inlineMarkdown(line.substring(2))).append("</h1>");
            } else if (line.startsWith("## ")) {
                if (inList) { html.append("</ul>"); inList = false; }
                html.append("<h2>").append(inlineMarkdown(line.substring(3))).append("</h2>");
            } else if (line.startsWith("- ")) {
                if (!inList) { html.append("<ul>"); inList = true; }
                html.append("<li>").append(inlineMarkdown(line.substring(2))).append("</li>");
            } else if (line.trim().length() == 0) {
                if (inList) { html.append("</ul>"); inList = false; }
            } else {
                if (inList) { html.append("</ul>"); inList = false; }
                html.append("<p>").append(inlineMarkdown(line)).append("</p>");
            }
        }
        if (inList) html.append("</ul>");
        return html.append("</body></html>").toString();
    }

    private String inlineMarkdown(String text) {
        return escapeHtml(text).replaceAll("`([^`]+)`", "<code>$1</code>")
                .replaceAll("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>");
    }

    private String escapeHtml(String text) {
        return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    private void quickFix() {
        String text = editor.getText().toString();
        String fixed = text;
        if (isLang("python")) {
            fixed = fixPython(fixed);
        }
        if (isCStyle(currentLanguage) || isLang("javascript") || isLang("typescript") || isLang("php")) {
            fixed = fixAssignmentInConditions(fixed);
            fixed = fixSimpleSemicolons(fixed);
        }
        if (isLang("css")) {
            fixed = fixCssSemicolons(fixed);
        }
        fixed = closeUnbalanced(fixed);
        if (!fixed.equals(text)) {
            editor.setText(fixed);
            editor.setSelection(Math.min(fixed.length(), Math.max(0, editor.getSelectionStart())));
            dirty = true;
            updateStatus("Fixed", ACCENT);
            runChecks();
        } else {
            updateStatus("Nothing to fix", DIM);
        }
    }

    private void runChecks() {
        if (currentLanguage == null) currentLanguage = detectLanguage(currentName);
        String text = editor.getText().toString();
        List<String> issues = new ArrayList<>();
        String[] lines = text.split("\n", -1);
        if (text.contains("\u00ab\u00bb")) {
            issues.add("line " + lineForOffset(text, text.indexOf("\u00ab\u00bb")) + ": template placeholder still needs code");
        }
        checkGenericStructure(text, lines, issues);
        addLanguageChecks(text, lines, issues);

        if (usesRuntimeSyntaxCheck()) {
            checkInWebRuntime(currentLanguage.id, text, issues);
        } else {
            finishChecks(issues);
        }
    }

    private void finishChecks(List<String> issues) {
        output.setText(formatIssues(issues));
        if (issues.isEmpty()) {
            appendOutput("info", "Static checks passed for " + currentLanguage.name + ".\n"
                    + "Checked delimiters, strings, comments, and " + currentLanguage.name + " rules.\n");
            updateStatus("Clean", ACCENT);
        } else {
            updateStatus(issues.size() + " issue" + (issues.size() == 1 ? "" : "s"), WARN);
        }
    }

    private String formatIssues(List<String> issues) {
        if (issues.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (String issue : issues) sb.append(issue).append('\n');
        return sb.toString();
    }

    private boolean usesRuntimeSyntaxCheck() {
        return isLang("python") || isLang("javascript") || isLang("typescript");
    }

    private void checkInWebRuntime(final String mode, final String code, List<String> staticIssues) {
        pendingStaticIssues = staticIssues.size();
        pendingRuntimeIssues = 0;
        output.setText(formatIssues(staticIssues));
        appendOutput("info", "$ check " + mode + " syntax (bundled runtime)\n");
        runnerWebView = new WebView(this);
        WebSettings settings = runnerWebView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setAllowFileAccessFromFileURLs(true);
        settings.setAllowUniversalAccessFromFileURLs(true);
        runnerWebView.addJavascriptInterface(new RunnerBridge(), "AndroidRunner");
        runnerWebView.setWebViewClient(new WebViewClient() {
            @Override public void onPageFinished(WebView view, String url) {
                String quotedCode = JSONObject.quote(code);
                String js;
                if ("python".equals(mode)) {
                    js = "GeskoRunner.checkPython(" + quotedCode + ")";
                } else {
                    js = "GeskoRunner.checkJavaScript(" + quotedCode + "," + JSONObject.quote(mode) + ")";
                }
                view.evaluateJavascript(js, null);
            }
        });
        runnerWebView.loadUrl("file:///android_asset/runner.html");
    }

    private void highlight() {
        Editable text = editor.getText();
        highlighting = true;
        ForegroundColorSpan[] old = text.getSpans(0, text.length(), ForegroundColorSpan.class);
        for (ForegroundColorSpan span : old) {
            text.removeSpan(span);
        }
        Language lang = currentLanguage == null ? languageById("text") : currentLanguage;
        applyRegex(text, "\\b\\d+(?:\\.\\d+)?\\b", NUMBER);
        applyRegex(text, "[(){}\\[\\]]", BRACKET);
        applyRegex(text, "[+\\-*/%=!<>|&]+", OP);

        Matcher word = Pattern.compile("\\b[A-Za-z_][A-Za-z0-9_]*\\b").matcher(text);
        while (word.find()) {
            String token = word.group();
            if (lang.keywords.contains(token)) {
                text.setSpan(new ForegroundColorSpan(KW), word.start(), word.end(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (lang.types.contains(token) || lang.builtins.contains(token)) {
                text.setSpan(new ForegroundColorSpan(BUILTIN), word.start(), word.end(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (lang.constants.contains(token)) {
                text.setSpan(new ForegroundColorSpan(NUMBER), word.start(), word.end(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
        }
        if (isLang("html")) {
            applyRegex(text, "</?[A-Za-z][A-Za-z0-9:-]*\\b|/?>|<![A-Za-z][^>]*>", KW);
            applyRegex(text, "\\b[a-zA-Z-:]+(?=\\s*=)", BUILTIN);
        } else if (isLang("markdown")) {
            applyRegex(text, "(?m)^#{1,6}\\s.*$", KW);
            applyRegex(text, "`[^`]*`", STRING);
            applyRegex(text, "\\[[^\\]]+\\]\\([^)]+\\)", BUILTIN);
        } else if (isLang("css")) {
            applyRegex(text, "[.#][A-Za-z_-][A-Za-z0-9_-]*", BUILTIN);
            applyRegex(text, "\\b[A-Za-z-]+(?=\\s*:)", KW);
        }
        applyStrings(text, lang);
        applyComments(text, lang);
        highlighting = false;
        updatePathLabel();
        editor.invalidate();
    }

    private void applyRegex(Editable text, String regex, int color) {
        try {
            Matcher matcher = Pattern.compile(regex).matcher(text);
            while (matcher.find()) {
                text.setSpan(new ForegroundColorSpan(color), matcher.start(), matcher.end(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
        } catch (Exception ignored) {
        }
    }

    private void loadLanguages() {
        try {
            InputStream in = getAssets().open("languages.json");
            JSONObject root = new JSONObject(readAll(in));
            JSONArray arr = root.getJSONArray("languages");
            for (int i = 0; i < arr.length(); i++) {
                JSONObject obj = arr.getJSONObject(i);
                JSONArray extsJson = obj.getJSONArray("exts");
                List<String> exts = new ArrayList<>();
                for (int j = 0; j < extsJson.length(); j++) {
                    exts.add(extsJson.getString(j));
                }
                JSONArray blockJson = obj.optJSONArray("block_comment");
                String blockStart = "";
                String blockEnd = "";
                if (blockJson != null && blockJson.length() >= 2) {
                    blockStart = blockJson.getString(0);
                    blockEnd = blockJson.getString(1);
                }
                addLanguage(new Language(
                        obj.getString("id"),
                        obj.getString("name"),
                        exts,
                        obj.optString("line_comment", ""),
                        blockStart,
                        blockEnd,
                        obj.optString("strings", ""),
                        obj.optBoolean("backtick", false),
                        splitWords(obj.optString("keywords", "")),
                        splitWords(obj.optString("types", "")),
                        splitWords(obj.optString("builtins", "")),
                        splitWords(obj.optString("constants", "")),
                        obj.optString("family", obj.getString("id")),
                        obj.optString("run", obj.getString("id")),
                        obj.optString("skeleton", "")));
            }
        } catch (Exception ex) {
            addLanguage(new Language("python", "Python", Arrays.asList(".py", ".pyw"), "#", "", "",
                    "\"'", false,
                    splitWords("and as assert async await break class continue def elif else except finally for from if import in is not or pass raise return try while with yield"),
                    splitWords("Exception ValueError TypeError SyntaxError"),
                    splitWords("print len range open input int float str bool list dict set tuple"),
                    splitWords("True False None"), "python", "python",
                    "#!/usr/bin/env python3\n\n\ndef main():\n    \u00ab\u00bb\n\n\nif __name__ == \"__main__\":\n    main()\n"));
            addLanguage(new Language("text", "Plain Text", Arrays.asList(".txt"), "#", "", "",
                    "\"'", false, new HashSet<String>(), new HashSet<String>(), new HashSet<String>(),
                    new HashSet<String>(), "text", "text", "\u00ab\u00bb\n"));
        }
        currentLanguage = languageById("python");
    }

    private void addLanguage(Language lang) {
        languages.add(lang);
        languagesById.put(lang.id, lang);
    }

    private String readAll(InputStream in) throws Exception {
        BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            sb.append(line).append('\n');
        }
        reader.close();
        return sb.toString();
    }

    private Set<String> splitWords(String words) {
        Set<String> out = new HashSet<>();
        for (String word : words.split("\\s+")) {
            if (word.length() > 0) out.add(word);
        }
        return out;
    }

    private Language languageById(String id) {
        Language lang = languagesById.get(id);
        return lang != null ? lang : languages.get(0);
    }

    private Language detectLanguage(String name) {
        String lower = name == null ? "" : name.toLowerCase(Locale.US);
        for (Language lang : languages) {
            for (String ext : lang.exts) {
                if (lower.endsWith(ext.toLowerCase(Locale.US))) {
                    return lang;
                }
            }
        }
        return languagesById.containsKey("text") ? languageById("text") : languages.get(0);
    }

    private boolean isLang(String id) {
        return currentLanguage != null && id.equals(currentLanguage.id);
    }

    private String fixPython(String text) {
        String[] lines = text.split("\n", -1);
        StringBuilder out = new StringBuilder(text.length() + 16);
        Pattern block = Pattern.compile("^(\\s*(if|elif|else|for|while|def|class|try|except|finally|with)\\b[^:#\\n]*)(\\s*(#.*)?)$");
        Pattern py2Print = Pattern.compile("^(\\s*)print\\s+([\"'].*[\"'])\\s*$");
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            Matcher print = py2Print.matcher(line);
            if (print.matches()) {
                line = print.group(1) + "print(" + print.group(2) + ")";
            }
            Matcher matcher = block.matcher(line);
            String trimmed = line.trim();
            if (matcher.matches() && !trimmed.endsWith(":") && !trimmed.endsWith("\\")) {
                line = matcher.group(1) + ":" + matcher.group(3);
            }
            out.append(line);
            if (i < lines.length - 1) out.append('\n');
        }
        return out.toString();
    }

    private String closeUnbalanced(String text) {
        ArrayDeque<Character> stack = new ArrayDeque<>();
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (ch == '(' || ch == '[' || ch == '{') {
                stack.push(ch);
            } else if ((ch == ')' || ch == ']' || ch == '}') && !stack.isEmpty()) {
                char open = stack.peek();
                if ((open == '(' && ch == ')') || (open == '[' && ch == ']') || (open == '{' && ch == '}')) {
                    stack.pop();
                }
            }
        }
        StringBuilder add = new StringBuilder();
        while (!stack.isEmpty()) {
            add.append(matchingClose(stack.pop()));
        }
        if (add.length() == 0) return text;
        return text + (text.endsWith("\n") ? "" : "\n") + add + "\n";
    }

    private char matchingClose(char open) {
        if (open == '(') return ')';
        if (open == '[') return ']';
        return '}';
    }

    private int lineForOffset(String text, int offset) {
        int line = 1;
        for (int i = 0; i < offset && i < text.length(); i++) {
            if (text.charAt(i) == '\n') line++;
        }
        return line;
    }

    private void checkGenericStructure(String text, String[] lines, List<String> issues) {
        Language lang = currentLanguage == null ? languageById("text") : currentLanguage;
        ArrayDeque<SourcePos> stack = new ArrayDeque<>();
        boolean inBlock = false;
        String activeBlockEnd = "";
        int blockLine = 0;
        char quote = 0;
        int quoteLine = 0;
        boolean escaped = false;

        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            int j = 0;
            while (j < line.length()) {
                if (inBlock) {
                    int end = activeBlockEnd.length() == 0 ? -1 : line.indexOf(activeBlockEnd, j);
                    if (end < 0) break;
                    inBlock = false;
                    j = end + activeBlockEnd.length();
                    continue;
                }
                char ch = line.charAt(j);
                if (quote != 0) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == quote) {
                        quote = 0;
                    }
                    j++;
                    continue;
                }
                if (isLang("python") && (startsAt(line, j, "\"\"\"") || startsAt(line, j, "'''"))) {
                    String mark = startsAt(line, j, "\"\"\"") ? "\"\"\"" : "'''";
                    int end = line.indexOf(mark, j + 3);
                    if (end < 0) {
                        inBlock = true;
                        activeBlockEnd = mark;
                        blockLine = i + 1;
                        break;
                    }
                    j = end + 3;
                    continue;
                }
                if (lang.blockStart.length() > 0 && startsAt(line, j, lang.blockStart)) {
                    inBlock = true;
                    activeBlockEnd = lang.blockEnd;
                    blockLine = i + 1;
                    j += lang.blockStart.length();
                    continue;
                }
                if (lang.lineComment.length() > 0 && startsAt(line, j, lang.lineComment)) {
                    break;
                }
                if (isStringQuote(ch, lang)) {
                    quote = ch;
                    quoteLine = i + 1;
                    escaped = false;
                    j++;
                    continue;
                }
                if (ch == '(' || ch == '[' || ch == '{') {
                    stack.push(new SourcePos(ch, i + 1, j + 1));
                } else if (ch == ')' || ch == ']' || ch == '}') {
                    if (stack.isEmpty()) {
                        issues.add("line " + (i + 1) + ": closing '" + ch + "' has no opener");
                    } else {
                        SourcePos open = stack.pop();
                        if (matchingClose(open.ch) != ch) {
                            issues.add("line " + (i + 1) + ": closing '" + ch
                                    + "' does not match '" + open.ch + "' from line " + open.line);
                        }
                    }
                }
                j++;
            }
            if (quote != 0 && !(lang.backtick && quote == '`')) {
                issues.add("line " + quoteLine + ": unterminated string literal");
                quote = 0;
            }
        }
        if (quote != 0) {
            issues.add("line " + quoteLine + ": unterminated multiline string");
        }
        if (inBlock) {
            issues.add("line " + blockLine + ": unclosed block comment/string");
        }
        while (!stack.isEmpty()) {
            SourcePos open = stack.removeLast();
            issues.add("line " + open.line + ": unclosed '" + open.ch + "'");
        }
    }

    private boolean startsAt(String text, int index, String needle) {
        return needle.length() > 0 && index + needle.length() <= text.length()
                && text.regionMatches(index, needle, 0, needle.length());
    }

    private boolean isStringQuote(char ch, Language lang) {
        return (ch == '"' && lang.strings.indexOf('"') >= 0)
                || (ch == '\'' && lang.strings.indexOf('\'') >= 0)
                || (ch == '`' && lang.backtick);
    }

    private void addLanguageChecks(String text, String[] lines, List<String> issues) {
        if (isLang("python")) checkPythonStatic(text, lines, issues);
        if (isLang("javascript") || isLang("typescript")) checkJavaScriptStatic(lines, issues);
        if (isCStyle(currentLanguage)) checkCStyleStatic(lines, issues);
        if (isLang("go")) checkGoStatic(text, lines, issues);
        if (isLang("rust")) checkRustStatic(lines, issues);
        if (isLang("css")) checkCss(lines, issues);
        if (isLang("sql")) checkSql(text, issues);
        if (isLang("json")) checkJson(text, issues);
        if (isLang("html")) checkHtml(text, issues);
        if (isLang("java")) checkJava(text, issues);
        if (isLang("shell")) checkShell(lines, issues);
        if (isLang("yaml")) checkYaml(lines, issues);
        if (isLang("ruby")) checkEndBlocks(lines, "Ruby", "\\b(def|class|module|if|unless|case|begin|do)\\b", "\\bend\\b", issues);
        if (isLang("lua")) checkEndBlocks(lines, "Lua", "\\b(function|if|for|while|do)\\b", "\\b(end|until)\\b", issues);
        if (isLang("applescript")) checkEndBlocks(lines, "AppleScript", "\\b(tell|if|repeat|try)\\b", "\\bend\\b", issues);
    }

    private void checkPythonStatic(String text, String[] lines, List<String> issues) {
        for (int i = 0; i < lines.length; i++) {
            String code = beforeLineComment(lines[i], "#");
            String trimmed = code.trim();
            if (trimmed.length() == 0) continue;
            String indent = leadingWhitespace(lines[i]);
            if (indent.indexOf('\t') >= 0 && indent.indexOf(' ') >= 0) {
                issues.add("line " + (i + 1) + ": mixed tabs and spaces in indentation");
            }
            if (isPythonBlockHeader(trimmed) && !trimmed.endsWith(":") && !trimmed.endsWith("\\")) {
                issues.add("line " + (i + 1) + ": missing ':' after Python block header");
            }
            if (trimmed.matches("print\\s+[^()].*")) {
                issues.add("line " + (i + 1) + ": Python 2 style print; use print(...)");
            }
            if ((trimmed.startsWith("if ") || trimmed.startsWith("elif ") || trimmed.startsWith("while "))
                    && hasSingleEquals(trimmed)) {
                issues.add("line " + (i + 1) + ": assignment '=' inside condition; did you mean '=='?");
            }
            if (trimmed.matches("from\\s+\\S+\\s+import\\s+\\*")) {
                issues.add("line " + (i + 1) + ": wildcard import makes undefined-name checks weaker");
            }
            if ("except:".equals(trimmed)) {
                issues.add("line " + (i + 1) + ": bare except catches everything");
            }
        }
    }

    private boolean isPythonBlockHeader(String trimmed) {
        return trimmed.matches("(async\\s+)?(def|class|if|elif|else|for|while|try|except|finally|with)\\b.*");
    }

    private void checkJavaScriptStatic(String[] lines, List<String> issues) {
        for (int i = 0; i < lines.length; i++) {
            String trimmed = beforeLineComment(lines[i], "//").trim();
            if (trimmed.length() == 0) continue;
            if (startsControlWithCondition(trimmed) && hasSingleEquals(trimmed)) {
                issues.add("line " + (i + 1) + ": assignment '=' inside condition; did you mean '==' or '==='?");
            }
            if (trimmed.matches("(let|const|var)\\s+[A-Za-z_$][\\w$]*\\s*=\\s*;?")) {
                issues.add("line " + (i + 1) + ": variable assignment is missing a value");
            }
            if (isLang("typescript") && trimmed.matches("(interface|type|enum)\\b.*") && !trimmed.endsWith("{")
                    && !trimmed.endsWith(";") && !trimmed.contains("=")) {
                issues.add("line " + (i + 1) + ": TypeScript declaration looks incomplete");
            }
        }
    }

    private void checkCStyleStatic(String[] lines, List<String> issues) {
        for (int i = 0; i < lines.length; i++) {
            String trimmed = beforeLineComment(lines[i], "//").trim();
            if (trimmed.length() == 0 || trimmed.startsWith("*")) continue;
            if (startsControlWithCondition(trimmed) && hasSingleEquals(trimmed)) {
                issues.add("line " + (i + 1) + ": assignment '=' inside condition; did you mean equality?");
            }
            if (needsSemicolon(currentLanguage) && looksLikeMissingSemicolon(trimmed)) {
                issues.add("line " + (i + 1) + ": statement may be missing ';'");
            }
        }
    }

    private void checkGoStatic(String text, String[] lines, List<String> issues) {
        if (!Pattern.compile("(?m)^\\s*package\\s+[A-Za-z_][A-Za-z0-9_]*").matcher(text).find()) {
            issues.add("line 1: Go files need a package declaration");
        }
        if (Pattern.compile("(?m)^\\s*package\\s+main\\b").matcher(text).find()
                && !Pattern.compile("(?m)^\\s*func\\s+main\\s*\\(").matcher(text).find()) {
            issues.add("line 1: package main usually needs func main()");
        }
        for (int i = 0; i < lines.length; i++) {
            String trimmed = beforeLineComment(lines[i], "//").trim();
            if (trimmed.startsWith("func ") && !trimmed.contains("{")) {
                issues.add("line " + (i + 1) + ": Go function header is missing '{'");
            }
        }
    }

    private void checkRustStatic(String[] lines, List<String> issues) {
        for (int i = 0; i < lines.length; i++) {
            String trimmed = beforeLineComment(lines[i], "//").trim();
            if (trimmed.startsWith("fn ") && !trimmed.contains("{")) {
                issues.add("line " + (i + 1) + ": Rust function header is missing '{'");
            }
            if (trimmed.startsWith("let ") && !trimmed.endsWith(";") && !trimmed.endsWith("{")) {
                issues.add("line " + (i + 1) + ": Rust let statement may be missing ';'");
            }
        }
    }

    private void checkCss(String[] lines, List<String> issues) {
        boolean inside = false;
        for (int i = 0; i < lines.length; i++) {
            String trimmed = lines[i].trim();
            if (trimmed.length() == 0 || trimmed.startsWith("/*") || trimmed.startsWith("*")) continue;
            if (trimmed.contains("{")) inside = true;
            if (inside && !trimmed.contains("{") && !trimmed.contains("}") && !trimmed.startsWith("@")) {
                if (!trimmed.contains(":")) {
                    issues.add("line " + (i + 1) + ": CSS declaration needs property: value");
                } else if (!trimmed.endsWith(";")) {
                    issues.add("line " + (i + 1) + ": CSS declaration may be missing ';'");
                }
            }
            if (trimmed.contains("}")) inside = false;
        }
    }

    private void checkSql(String text, List<String> issues) {
        SQLiteDatabase db = null;
        try {
            db = SQLiteDatabase.create(null);
            for (String stmt : splitSql(text)) {
                String trimmed = stmt.trim();
                if (trimmed.length() == 0) continue;
                if (isQuery(trimmed)) {
                    Cursor c = db.rawQuery("EXPLAIN QUERY PLAN " + trimmed, null);
                    c.close();
                } else {
                    db.execSQL(trimmed);
                }
            }
        } catch (Exception ex) {
            issues.add("SQL check: " + ex.getMessage());
        } finally {
            if (db != null) db.close();
        }
    }

    private void checkYaml(String[] lines, List<String> issues) {
        int previousIndent = 0;
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = line.trim();
            if (trimmed.length() == 0 || trimmed.startsWith("#")) continue;
            if (line.startsWith("\t")) {
                issues.add("line " + (i + 1) + ": YAML indentation should use spaces, not tabs");
            }
            int indent = leadingWhitespace(line).length();
            if (indent % 2 != 0) {
                issues.add("line " + (i + 1) + ": YAML indentation is odd; two-space steps are safer");
            }
            if (indent > previousIndent + 2) {
                issues.add("line " + (i + 1) + ": YAML indentation jumps more than one level");
            }
            previousIndent = indent;
        }
    }

    private void checkEndBlocks(String[] lines, String name, String openRegex, String closeRegex, List<String> issues) {
        Pattern open = Pattern.compile(openRegex);
        Pattern close = Pattern.compile(closeRegex);
        int depth = 0;
        int firstOpen = 0;
        for (int i = 0; i < lines.length; i++) {
            String trimmed = lines[i].trim();
            if (trimmed.length() == 0 || trimmed.startsWith("#") || trimmed.startsWith("--")) continue;
            if (open.matcher(trimmed).find()) {
                if (depth == 0) firstOpen = i + 1;
                depth++;
            }
            if (close.matcher(trimmed).find()) {
                depth--;
                if (depth < 0) {
                    issues.add("line " + (i + 1) + ": " + name + " has an extra end/close token");
                    depth = 0;
                }
            }
        }
        if (depth > 0) {
            issues.add("line " + firstOpen + ": " + name + " block may be missing end");
        }
    }

    private boolean startsControlWithCondition(String trimmed) {
        return trimmed.startsWith("if") || trimmed.startsWith("while")
                || trimmed.startsWith("switch");
    }

    private boolean hasSingleEquals(String text) {
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) != '=') continue;
            char prev = i > 0 ? text.charAt(i - 1) : 0;
            char next = i + 1 < text.length() ? text.charAt(i + 1) : 0;
            if (prev != '=' && prev != '!' && prev != '<' && prev != '>' && prev != ':' && next != '=' && next != '>') {
                return true;
            }
        }
        return false;
    }

    private String beforeLineComment(String line, String marker) {
        if (marker == null || marker.length() == 0) return line;
        int idx = line.indexOf(marker);
        return idx < 0 ? line : line.substring(0, idx);
    }

    private String leadingWhitespace(String line) {
        int i = 0;
        while (i < line.length() && Character.isWhitespace(line.charAt(i)) && line.charAt(i) != '\n') i++;
        return line.substring(0, i);
    }

    private boolean isCStyle(Language lang) {
        if (lang == null) return false;
        return "c".equals(lang.id) || "cpp".equals(lang.id) || "csharp".equals(lang.id)
                || "java".equals(lang.id) || "javascript".equals(lang.id) || "typescript".equals(lang.id)
                || "kotlin".equals(lang.id) || "swift".equals(lang.id) || "php".equals(lang.id)
                || "perl".equals(lang.id);
    }

    private boolean needsSemicolon(Language lang) {
        if (lang == null) return false;
        return "c".equals(lang.id) || "cpp".equals(lang.id) || "csharp".equals(lang.id)
                || "java".equals(lang.id) || "php".equals(lang.id) || "perl".equals(lang.id);
    }

    private boolean looksLikeMissingSemicolon(String trimmed) {
        if (trimmed.endsWith(";") || trimmed.endsWith("{") || trimmed.endsWith("}") || trimmed.endsWith(":")
                || trimmed.startsWith("#") || trimmed.startsWith("@")) {
            return false;
        }
        if (trimmed.matches("(if|for|while|switch|catch|else|try|finally|class|struct|enum|interface|namespace)\\b.*")) {
            return false;
        }
        return trimmed.matches("(return|break|continue|throw|import|package|using|echo|print)\\b.*")
                || trimmed.matches(".*\\b(int|long|short|float|double|char|bool|boolean|String|string|var|auto)\\b\\s+[A-Za-z_$][\\w$]*.*")
                || trimmed.matches("[$A-Za-z_][\\w$]*(\\.[A-Za-z_][\\w$]*|\\[[^]]*\\])*\\s*=.*")
                || trimmed.matches("[A-Za-z_][\\w$]*\\s*\\([^;{}]*\\)");
    }

    private String fixAssignmentInConditions(String text) {
        String[] lines = text.split("\n", -1);
        StringBuilder out = new StringBuilder(text.length());
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = line.trim();
            if (startsControlWithCondition(trimmed) && hasSingleEquals(trimmed)) {
                line = replaceFirstSingleEquals(line);
            }
            out.append(line);
            if (i < lines.length - 1) out.append('\n');
        }
        return out.toString();
    }

    private String replaceFirstSingleEquals(String line) {
        for (int i = 0; i < line.length(); i++) {
            if (line.charAt(i) != '=') continue;
            char prev = i > 0 ? line.charAt(i - 1) : 0;
            char next = i + 1 < line.length() ? line.charAt(i + 1) : 0;
            if (prev != '=' && prev != '!' && prev != '<' && prev != '>' && prev != ':' && next != '=' && next != '>') {
                return line.substring(0, i) + "==" + line.substring(i + 1);
            }
        }
        return line;
    }

    private String fixSimpleSemicolons(String text) {
        if (!needsSemicolon(currentLanguage)) return text;
        String[] lines = text.split("\n", -1);
        StringBuilder out = new StringBuilder(text.length() + lines.length);
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = beforeLineComment(line, currentLanguage.lineComment).trim();
            if (looksLikeMissingSemicolon(trimmed)) {
                line = line + ";";
            }
            out.append(line);
            if (i < lines.length - 1) out.append('\n');
        }
        return out.toString();
    }

    private String fixCssSemicolons(String text) {
        String[] lines = text.split("\n", -1);
        boolean inside = false;
        StringBuilder out = new StringBuilder(text.length() + lines.length);
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = line.trim();
            if (trimmed.contains("{")) inside = true;
            if (inside && trimmed.contains(":") && !trimmed.endsWith(";")
                    && !trimmed.endsWith("{") && !trimmed.contains("}")) {
                line = line + ";";
            }
            if (trimmed.contains("}")) inside = false;
            out.append(line);
            if (i < lines.length - 1) out.append('\n');
        }
        return out.toString();
    }

    private String buildStaticDebugReport(String text, String title) {
        List<String> issues = new ArrayList<>();
        String[] lines = text.split("\n", -1);
        checkGenericStructure(text, lines, issues);
        addLanguageChecks(text, lines, issues);

        StringBuilder sb = new StringBuilder();
        sb.append("$ debug ").append(currentLanguage.name).append(" (").append(title).append(")\n");
        sb.append("Static trace, symbols, and diagnostics. This does not install anything.\n\n");
        sb.append("Symbols / sections\n");
        List<String> symbols = collectSymbols(lines);
        if (symbols.isEmpty()) {
            sb.append("  line 1: top-level file\n");
        } else {
            for (String symbol : symbols) sb.append("  ").append(symbol).append('\n');
        }
        sb.append("\nExecutable-looking lines\n");
        int count = 0;
        for (int i = 0; i < lines.length && count < 80; i++) {
            String trimmed = beforeLineComment(lines[i], currentLanguage.lineComment).trim();
            if (trimmed.length() == 0 || trimmed.endsWith("{") || trimmed.endsWith("}")) continue;
            sb.append("  line ").append(i + 1).append(": ").append(firstLine(trimmed)).append('\n');
            count++;
        }
        if (count == 0) sb.append("  none found\n");
        sb.append("\nDiagnostics\n");
        if (issues.isEmpty()) {
            sb.append("  no static issues found\n");
        } else {
            for (String issue : issues) sb.append("  ").append(issue).append('\n');
        }
        return sb.toString();
    }

    private List<String> collectSymbols(String[] lines) {
        List<String> out = new ArrayList<>();
        for (int i = 0; i < lines.length; i++) {
            String trimmed = lines[i].trim();
            String item = symbolForLine(trimmed);
            if (item != null) out.add("line " + (i + 1) + ": " + item);
            if (out.size() >= 120) break;
        }
        return out;
    }

    private String symbolForLine(String trimmed) {
        Matcher m;
        if (isLang("python")) {
            m = Pattern.compile("^(def|class)\\s+([A-Za-z_][\\w]*)").matcher(trimmed);
            if (m.find()) return m.group(1) + " " + m.group(2);
        }
        if (isLang("javascript") || isLang("typescript")) {
            m = Pattern.compile("^(?:export\\s+)?(?:async\\s+)?function\\s+([A-Za-z_$][\\w$]*)").matcher(trimmed);
            if (m.find()) return "function " + m.group(1);
            m = Pattern.compile("^(?:export\\s+)?class\\s+([A-Za-z_$][\\w$]*)").matcher(trimmed);
            if (m.find()) return "class " + m.group(1);
        }
        if (isLang("go")) {
            m = Pattern.compile("^func\\s+(?:\\([^)]*\\)\\s*)?([A-Za-z_][\\w]*)").matcher(trimmed);
            if (m.find()) return "func " + m.group(1);
        }
        if (isLang("rust")) {
            m = Pattern.compile("^(fn|struct|enum|impl)\\s+([A-Za-z_][\\w]*)?").matcher(trimmed);
            if (m.find()) return m.group(1) + (m.group(2) == null ? "" : " " + m.group(2));
        }
        if (isLang("sql")) {
            m = Pattern.compile("(?i)^create\\s+(table|view|index|trigger|function|procedure)\\s+([A-Za-z_][\\w.]*)").matcher(trimmed);
            if (m.find()) return m.group(1).toLowerCase(Locale.US) + " " + m.group(2);
        }
        if (isLang("markdown") && trimmed.startsWith("#")) {
            return trimmed.replaceFirst("^#+\\s*", "section ");
        }
        if (isLang("css") && trimmed.endsWith("{")) {
            return "selector " + trimmed.substring(0, trimmed.length() - 1).trim();
        }
        m = Pattern.compile("^(class|struct|interface|enum|fun|func|function|def|sub)\\s+([A-Za-z_$][\\w$]*)").matcher(trimmed);
        if (m.find()) return m.group(1) + " " + m.group(2);
        return null;
    }

    private void checkJson(String text, List<String> issues) {
        try {
            JSONTokener tokener = new JSONTokener(text);
            tokener.nextValue();
            if (tokener.nextClean() != 0) {
                issues.add("JSON has extra data after the first value");
            }
        } catch (Exception ex) {
            issues.add("JSON parse error: " + ex.getMessage());
        }
    }

    private void checkHtml(String text, List<String> issues) {
        Set<String> voidTags = new HashSet<>(Arrays.asList(
                "area", "base", "br", "col", "embed", "hr", "img", "input",
                "link", "meta", "param", "source", "track", "wbr"));
        ArrayDeque<String> stack = new ArrayDeque<>();
        Matcher matcher = Pattern.compile("<(/?)([A-Za-z][A-Za-z0-9:-]*)([^>]*)>").matcher(text);
        while (matcher.find()) {
            String close = matcher.group(1);
            String tag = matcher.group(2).toLowerCase(Locale.US);
            String rest = matcher.group(3);
            if (voidTags.contains(tag) || rest.trim().endsWith("/")) continue;
            if (close.length() == 0) {
                stack.push(tag);
            } else if (stack.isEmpty()) {
                issues.add("HTML closing tag without opener: </" + tag + ">");
            } else {
                String open = stack.pop();
                if (!open.equals(tag)) {
                    issues.add("HTML tag mismatch: expected </" + open + "> before </" + tag + ">");
                }
            }
        }
        if (!stack.isEmpty()) {
            issues.add("HTML unclosed tag: <" + stack.peek() + ">");
        }
    }

    private void checkJava(String text, List<String> issues) {
        if (currentName == null || !currentName.endsWith(".java")) return;
        Matcher matcher = Pattern.compile("\\bpublic\\s+class\\s+([A-Za-z_$][A-Za-z0-9_$]*)").matcher(text);
        if (matcher.find()) {
            String expected = currentName.substring(0, currentName.length() - 5);
            if (!expected.equals(matcher.group(1))) {
                issues.add("Java public class should match file name: " + expected);
            }
        }
    }

    private void checkShell(String[] lines, List<String> issues) {
        int ifs = 0;
        int dos = 0;
        int cases = 0;
        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.startsWith("#")) continue;
            if (trimmed.matches(".*\\bif\\b.*")) ifs++;
            if (trimmed.matches(".*\\bfi\\b.*")) ifs--;
            if (trimmed.matches(".*\\b(do)$")) dos++;
            if (trimmed.matches(".*\\bdone\\b.*")) dos--;
            if (trimmed.matches(".*\\bcase\\b.*")) cases++;
            if (trimmed.matches(".*\\besac\\b.*")) cases--;
        }
        if (ifs > 0) issues.add("shell block may be missing 'fi'");
        if (dos > 0) issues.add("shell loop may be missing 'done'");
        if (cases > 0) issues.add("shell case may be missing 'esac'");
    }

    private void applyStrings(Editable text, Language lang) {
        if (isLang("python")) {
            applyRegex(text, "(?s)\"\"\".*?\"\"\"|'''.*?'''", STRING);
        }
        if (lang.strings.contains("\"")) {
            applyRegex(text, "\"([^\"\\\\]|\\\\.)*\"", STRING);
        }
        if (lang.strings.contains("'")) {
            applyRegex(text, "'([^'\\\\]|\\\\.)*'", STRING);
        }
        if (lang.backtick) {
            applyRegex(text, "`([^`\\\\]|\\\\.)*`", STRING);
        }
    }

    private void applyComments(Editable text, Language lang) {
        if (lang.lineComment.length() > 0 && !"text".equals(lang.id)) {
            applyRegex(text, "(?m)" + Pattern.quote(lang.lineComment) + ".*$", COMMENT);
        }
        if (lang.blockStart.length() > 0 && lang.blockEnd.length() > 0) {
            applyRegex(text, "(?s)" + Pattern.quote(lang.blockStart) + ".*?" + Pattern.quote(lang.blockEnd), COMMENT);
        }
    }

    private void updatePathLabel() {
        String mark = dirty ? " *" : "";
        String uriText = currentUri == null ? "local draft" : currentUri.toString();
        String lang = currentLanguage == null ? "" : currentLanguage.name + "  -  ";
        pathLabel.setText(currentName + mark + "  -  " + lang + uriText);
    }

    private void updateStatus(String message, int color) {
        int lines = editor == null ? 0 : editor.getLineCount();
        int chars = editor == null ? 0 : editor.length();
        String lang = currentLanguage == null ? "Text" : currentLanguage.name;
        status.setText(String.format(Locale.US, "%s   %s   lines %d   chars %d", message, lang, lines, chars));
        status.setTextColor(color);
        updatePathLabel();
    }

    private void showKeyboard() {
        editor.requestFocus();
        editor.postDelayed(new Runnable() {
            @Override public void run() {
                InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) imm.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT);
            }
        }, 150);
    }

    private void showError(String title, Exception ex) {
        updateStatus("Error", ERROR);
        new AlertDialog.Builder(this)
                .setTitle(title)
                .setMessage(ex.getClass().getSimpleName() + ": " + ex.getMessage())
                .setPositiveButton("OK", null)
                .show();
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    private static class SourcePos {
        final char ch;
        final int line;
        final int col;

        SourcePos(char ch, int line, int col) {
            this.ch = ch;
            this.line = line;
            this.col = col;
        }
    }

    private static class Language {
        final String id;
        final String name;
        final List<String> exts;
        final String lineComment;
        final String blockStart;
        final String blockEnd;
        final String strings;
        final boolean backtick;
        final Set<String> keywords;
        final Set<String> types;
        final Set<String> builtins;
        final Set<String> constants;
        final String family;
        final String run;
        final String skeleton;

        Language(String id, String name, List<String> exts, String lineComment,
                 String blockStart, String blockEnd, String strings, boolean backtick,
                 Set<String> keywords, Set<String> types, Set<String> builtins,
                 Set<String> constants, String family, String run, String skeleton) {
            this.id = id;
            this.name = name;
            this.exts = exts;
            this.lineComment = lineComment == null ? "" : lineComment;
            this.blockStart = blockStart == null ? "" : blockStart;
            this.blockEnd = blockEnd == null ? "" : blockEnd;
            this.strings = strings == null ? "" : strings;
            this.backtick = backtick;
            this.keywords = keywords;
            this.types = types;
            this.builtins = builtins;
            this.constants = constants;
            this.family = family;
            this.run = run;
            this.skeleton = skeleton == null ? "" : skeleton;
        }

        String defaultExt() {
            return exts.isEmpty() ? ".txt" : exts.get(0);
        }
    }

    public static class CodeEditor extends android.widget.EditText {
        private final Paint gutterPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint gutterTextPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint currentPaint = new Paint();
        private final Paint borderPaint = new Paint();
        private final int gutterWidth;
        private final Rect clip = new Rect();

        public CodeEditor(Context context) {
            super(context);
            gutterWidth = dp(context, 54);
            setPadding(gutterWidth + dp(context, 10), dp(context, 10), dp(context, 12), dp(context, 14));
            setLineSpacing(dp(context, 2), 1.0f);
            gutterPaint.setColor(GUTTER_BG);
            currentPaint.setColor(CURRENT_LINE);
            borderPaint.setColor(BORDER);
            gutterTextPaint.setColor(FAINT);
            gutterTextPaint.setTextAlign(Paint.Align.RIGHT);
            gutterTextPaint.setTextSize(dp(context, 12));
            gutterTextPaint.setTypeface(Typeface.MONOSPACE);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            getDrawingRect(clip);
            canvas.drawRect(0, clip.top + getScrollY(), gutterWidth, clip.bottom + getScrollY(), gutterPaint);
            if (getLayout() != null) {
                int selectionLine = getLayout().getLineForOffset(Math.max(0, getSelectionStart()));
                int top = getLayout().getLineTop(selectionLine) + getTotalPaddingTop();
                int bottom = getLayout().getLineBottom(selectionLine) + getTotalPaddingTop();
                canvas.drawRect(gutterWidth, top, getWidth() + getScrollX(), bottom, currentPaint);
                int first = getLayout().getLineForVertical(getScrollY());
                int last = getLayout().getLineForVertical(getScrollY() + getHeight());
                for (int i = first; i <= last; i++) {
                    int baseline = getLayout().getLineBaseline(i) + getTotalPaddingTop();
                    canvas.drawText(String.valueOf(i + 1), gutterWidth - dp(getContext(), 10), baseline, gutterTextPaint);
                }
            }
            canvas.drawRect(gutterWidth - 1, getScrollY(), gutterWidth, getScrollY() + getHeight(), borderPaint);
            super.onDraw(canvas);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            boolean result = super.onTouchEvent(event);
            invalidate();
            return result;
        }

        private static int dp(Context context, int value) {
            return (int) (value * context.getResources().getDisplayMetrics().density + 0.5f);
        }
    }
}
