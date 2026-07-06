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
    private LinearLayout outlinePanel;
    private LinearLayout outlineList;
    private WebView runnerWebView;
    private Uri currentUri;
    private String currentName = "untitled.py";
    private Language currentLanguage;
    private final List<CheckIssue> lastIssues = new ArrayList<>();
    private boolean outlineVisible;
    private boolean dirty;
    private boolean highlighting;

    private final Runnable highlightRunnable = new Runnable() {
        @Override
        public void run() {
            highlight();
        }
    };

    private final Runnable outlineRunnable = new Runnable() {
        @Override
        public void run() {
            updateOutline();
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            loadLanguages();
            buildUi();
            loadInitialDocument();
        } catch (Throwable ex) {
            buildSafeUi(ex);
        }
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

        addButton(tools, "Outline", new View.OnClickListener() {
            @Override public void onClick(View v) { toggleOutline(); }
        });
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

        editor = new CodeEditor(this);
        editor.setTextSize(15);
        editor.setTextColor(FG);
        editor.setHintTextColor(FAINT);
        editor.setGravity(Gravity.TOP | Gravity.START);
        editor.setTypeface(Typeface.MONOSPACE);
        editor.setBackgroundColor(EDITOR_BG);
        editor.setHorizontallyScrolling(true);
        editor.setVerticalScrollBarEnabled(true);
        editor.setHorizontalScrollBarEnabled(true);
        editor.setScrollBarStyle(View.SCROLLBARS_INSIDE_INSET);
        editor.setScrollbarFadingEnabled(false);
        editor.setOverScrollMode(View.OVER_SCROLL_ALWAYS);
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
                    if (outlineVisible) {
                        handler.removeCallbacks(outlineRunnable);
                        handler.postDelayed(outlineRunnable, 350);
                    }
                }
            }
        });

        LinearLayout editorRow = new LinearLayout(this);
        editorRow.setOrientation(LinearLayout.HORIZONTAL);
        editorRow.setBackgroundColor(EDITOR_BG);
        root.addView(editorRow, new LinearLayout.LayoutParams(-1, 0, 1f));

        outlinePanel = new LinearLayout(this);
        outlinePanel.setOrientation(LinearLayout.VERTICAL);
        outlinePanel.setBackgroundColor(PANEL);
        outlinePanel.setPadding(0, dp(6), 0, dp(6));
        TextView outlineTitle = new TextView(this);
        outlineTitle.setText("OUTLINE");
        outlineTitle.setTextColor(DIM);
        outlineTitle.setTypeface(Typeface.DEFAULT_BOLD);
        outlineTitle.setTextSize(12);
        outlineTitle.setPadding(dp(12), dp(3), dp(8), dp(6));
        outlinePanel.addView(outlineTitle, new LinearLayout.LayoutParams(-1, -2));
        ScrollView outlineScroll = new ScrollView(this);
        outlineScroll.setScrollbarFadingEnabled(false);
        outlineList = new LinearLayout(this);
        outlineList.setOrientation(LinearLayout.VERTICAL);
        outlineScroll.addView(outlineList, new ScrollView.LayoutParams(-1, -2));
        outlinePanel.addView(outlineScroll, new LinearLayout.LayoutParams(-1, 0, 1f));
        outlinePanel.setVisibility(View.GONE);
        editorRow.addView(outlinePanel, new LinearLayout.LayoutParams(dp(230), -1));
        editorRow.addView(editor, new LinearLayout.LayoutParams(0, -1, 1f));

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

    private void buildSafeUi(Throwable startupError) {
        if (languages.isEmpty()) {
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
        addButton(tools, "Fix", new View.OnClickListener() {
            @Override public void onClick(View v) { quickFix(); }
        });
        addButton(tools, "Check", new View.OnClickListener() {
            @Override public void onClick(View v) { runChecks(); }
        });
        addButton(tools, "Run", new View.OnClickListener() {
            @Override public void onClick(View v) { runActive(); }
        });

        outlinePanel = new LinearLayout(this);
        outlineList = new LinearLayout(this);
        outlineVisible = false;

        editor = new CodeEditor(this);
        editor.setTextSize(15);
        editor.setTextColor(FG);
        editor.setHintTextColor(FAINT);
        editor.setGravity(Gravity.TOP | Gravity.START);
        editor.setTypeface(Typeface.MONOSPACE);
        editor.setBackgroundColor(EDITOR_BG);
        editor.setHorizontallyScrolling(true);
        editor.setVerticalScrollBarEnabled(true);
        editor.setHorizontalScrollBarEnabled(true);
        editor.setScrollbarFadingEnabled(false);
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
        root.addView(outputScroll, new LinearLayout.LayoutParams(-1, dp(128)));

        status = new TextView(this);
        status.setTextColor(DIM);
        status.setTextSize(12);
        status.setSingleLine(true);
        status.setPadding(dp(12), dp(7), dp(12), dp(7));
        status.setBackgroundColor(STATUS_BG);
        root.addView(status, new LinearLayout.LayoutParams(-1, -2));

        currentName = "untitled.py";
        try {
            setDocument(currentName, languageById("python").skeleton);
        } catch (Throwable ignored) {
            editor.setText(languageById("python").skeleton);
        }
        dirty = false;
        updateStatus("Ready", ACCENT);
        output.setText("GeskoIDE opened in safe mode after a startup error.\n"
                + startupError.getClass().getSimpleName() + ": "
                + String.valueOf(startupError.getMessage()) + "\n"
                + "Editing, open/save, check, fix, and run still work here.");
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
                + "Run works offline for Python, Go, JavaScript, basic TypeScript, SQL, Shell, HTML, CSS, Markdown, and JSON.");
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
                updateOutlineIfVisible();
                updateStatus(currentLanguage.name, ACCENT);
                output.setText("Language set to " + currentLanguage.name + ".");
                return true;
            }
        });
        menu.show();
    }

    private void toggleOutline() {
        outlineVisible = !outlineVisible;
        outlinePanel.setVisibility(outlineVisible ? View.VISIBLE : View.GONE);
        if (outlineVisible) {
            updateOutline();
        }
    }

    private void updateOutlineIfVisible() {
        if (outlineVisible) {
            updateOutline();
        }
    }

    private void updateOutline() {
        if (outlineList == null) return;
        outlineList.removeAllViews();
        List<OutlineItem> items = buildOutline(editor.getText().toString());
        if (items.isEmpty()) {
            TextView empty = outlineRowText("No outline items yet.", 0, false);
            outlineList.addView(empty);
            return;
        }
        for (final OutlineItem item : items) {
            TextView row = outlineRowText(String.format(Locale.US, "%4d  %s %s",
                    item.line, item.kind, item.name), item.level, true);
            row.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) {
                    goToLine(item.line);
                }
            });
            outlineList.addView(row);
        }
    }

    private TextView outlineRowText(String text, int level, boolean active) {
        TextView row = new TextView(this);
        row.setText(text);
        row.setSingleLine(true);
        row.setTextSize(12);
        row.setTypeface(Typeface.MONOSPACE);
        row.setTextColor(active ? FG : FAINT);
        row.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);
        row.setPadding(dp(10 + level * 14), dp(5), dp(8), dp(5));
        row.setBackgroundColor(PANEL);
        return row;
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
        updateOutlineIfVisible();
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
        if (currentLanguage == null) currentLanguage = detectLanguage(currentName);
        String id = currentLanguage.id;
        String text = editor.getText().toString();
        output.setText("");
        updateStatus("Running", INFO);
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
            output.setText("No bundled runtime for " + currentLanguage.name + " in this APK build.\n"
                    + "This is honest: GeskoIDE can edit, color, template, fix, and check this file, "
                    + "but a real " + currentLanguage.name + " compiler/runtime is not bundled here.");
            updateStatus("No runner", WARN);
        }
    }

    private void runInWebRuntime(final String mode, final String code) {
        appendOutput("info", "$ run " + mode + " (bundled offline runtime)\n");
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
                } else if ("go".equals(mode)) {
                    js = "GeskoRunner.runGo(" + quotedCode + ")";
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
                        if ("done".equals(kind)) {
                            updateStatus("0".equals(message) ? "Run finished" : "Run failed",
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
        output.setText("$ run sql (Android SQLite)\n");
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
        output.setText("$ /system/bin/sh script\n");
        new Thread(new Runnable() {
            @Override public void run() {
                StringBuilder result = new StringBuilder();
                boolean ok = true;
                try {
                    File script = new File(getCacheDir(), "geskoide-run.sh");
                    FileOutputStream out = new FileOutputStream(script);
                    out.write(text.getBytes(StandardCharsets.UTF_8));
                    out.close();
                    Process proc = new ProcessBuilder("/system/bin/sh", script.getAbsolutePath())
                            .directory(getCacheDir()).redirectErrorStream(true).start();
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
        int cursor = Math.max(0, editor.getSelectionStart());
        List<CheckIssue> issues = collectIssues(text);
        String fixed = applyFixes(text, issues);
        if (!fixed.equals(text)) {
            editor.setText(fixed);
            editor.setSelection(Math.min(fixed.length(), cursor));
            dirty = true;
            updateStatus("Fixed", ACCENT);
            updateOutlineIfVisible();
            runChecks();
        } else {
            int fixable = 0;
            for (CheckIssue issue : issues) {
                if (issue.fix != null) fixable++;
            }
            output.setText(fixable == 0
                    ? "No automatic fix is available for the current checker issues.\n"
                    : "No text changed. The automatic fix was already applied or could not be placed safely.\n");
            updateStatus("Nothing to fix", DIM);
        }
    }

    private void runChecks() {
        String text = editor.getText().toString();
        List<CheckIssue> issues = collectIssues(text);
        lastIssues.clear();
        lastIssues.addAll(issues);
        if (issues.isEmpty()) {
            output.setText("No checker issues found.\nUse Run to execute supported languages.");
            updateStatus("Clean", ACCENT);
        } else {
            StringBuilder sb = new StringBuilder();
            for (CheckIssue issue : issues) {
                sb.append(issue.message);
                if (issue.fix != null) sb.append("  [Fix]");
                sb.append('\n');
            }
            output.setText(sb.toString());
            updateStatus(issues.size() + " issue" + (issues.size() == 1 ? "" : "s"), WARN);
        }
    }

    private List<CheckIssue> collectIssues(String text) {
        List<CheckIssue> issues = new ArrayList<>();
        String[] lines = text.split("\n", -1);
        ArrayDeque<Character> stack = new ArrayDeque<>();
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = line.trim();
            if (trimmed.startsWith("if ") || trimmed.startsWith("for ") || trimmed.startsWith("while ")
                    || trimmed.startsWith("def ") || trimmed.startsWith("class ") || trimmed.startsWith("else")
                    || trimmed.startsWith("elif ") || trimmed.startsWith("try") || trimmed.startsWith("except")
                    || trimmed.startsWith("finally") || trimmed.startsWith("with ")) {
                if (!trimmed.endsWith(":") && isLang("python")) {
                    addIssue(issues, i + 1, "missing ':'", "colon", null);
                }
            }
            if (trimmed.startsWith("print ") && !trimmed.startsWith("print(") && isLang("python")) {
                addIssue(issues, i + 1, "Python 2 style print", "print_call", null);
            }
            if (isSemicolonLanguage() && semicolonCandidate(trimmed)) {
                addIssue(issues, i + 1, "statement may be missing ';'", "semicolon", null);
            }
            if (isLang("yaml") && line.startsWith("\t")) {
                addIssue(issues, i + 1, "YAML indentation should use spaces, not tabs", "yaml_tabs", null);
            }
            for (int j = 0; j < line.length(); j++) {
                char ch = line.charAt(j);
                if (ch == '(' || ch == '{' || ch == '[') {
                    stack.push(ch);
                } else if (ch == ')' || ch == '}' || ch == ']') {
                    if (!stack.isEmpty() && matchingClose(stack.peek()) == ch) {
                        stack.pop();
                    } else {
                        addIssue(issues, i + 1, "extra '" + ch + "'", null, null);
                    }
                }
            }
        }
        if (!stack.isEmpty()) {
            StringBuilder closes = new StringBuilder();
            while (!stack.isEmpty()) {
                closes.append(matchingClose(stack.pop()));
            }
            addIssue(issues, lines.length, "unclosed bracket(s)", "append_eof", closes.toString());
        }
        addLanguageChecks(text, lines, issues);
        return issues;
    }

    private void addIssue(List<CheckIssue> issues, int line, String message, String fix, String data) {
        issues.add(new CheckIssue(line, "line " + Math.max(1, line) + ": " + message, fix, data));
    }

    private boolean isSemicolonLanguage() {
        return isLang("c") || isLang("cpp") || isLang("java") || isLang("csharp");
    }

    private boolean semicolonCandidate(String trimmed) {
        if (trimmed.length() == 0) return false;
        if (trimmed.startsWith("#") || trimmed.startsWith("@") || trimmed.startsWith("//")
                || trimmed.startsWith("/*") || trimmed.startsWith("*") || trimmed.startsWith("}")) {
            return false;
        }
        if (trimmed.endsWith(";") || trimmed.endsWith("{") || trimmed.endsWith("}") || trimmed.endsWith(":")) {
            return false;
        }
        String first = trimmed.split("\\s+", 2)[0];
        if (Arrays.asList("if", "else", "for", "while", "switch", "case", "default",
                "try", "catch", "finally", "class", "interface", "enum", "namespace",
                "public", "private", "protected", "using", "import", "package").contains(first)) {
            return false;
        }
        char last = trimmed.charAt(trimmed.length() - 1);
        return Character.isLetterOrDigit(last) || last == ')' || last == ']' || last == '"' || last == '\'';
    }

    private String applyFixes(String text, List<CheckIssue> issues) {
        String[] lines = text.split("\n", -1);
        StringBuilder append = new StringBuilder();
        boolean changed = false;
        for (CheckIssue issue : issues) {
            if (issue.fix == null) continue;
            if ("append_eof".equals(issue.fix)) {
                if (issue.data != null && issue.data.length() > 0) {
                    append.append(issue.data);
                    if (!issue.data.endsWith("\n")) append.append('\n');
                    changed = true;
                }
                continue;
            }
            int idx = Math.max(0, Math.min(lines.length - 1, issue.line - 1));
            String before = lines[idx];
            String after = fixLine(before, issue);
            if (after != null && !after.equals(before)) {
                lines[idx] = after;
                changed = true;
            }
        }
        String fixed = joinLines(lines);
        if (append.length() > 0) {
            if (!fixed.endsWith("\n")) fixed += "\n";
            fixed += append.toString();
        }
        return changed ? fixed : text;
    }

    private String fixLine(String line, CheckIssue issue) {
        if ("colon".equals(issue.fix)) {
            String[] parts = splitLineComment(line);
            String code = parts[0].trim().endsWith(":") ? parts[0] : parts[0].replaceFirst("\\s+$", "") + ":";
            return code + parts[1];
        }
        if ("print_call".equals(issue.fix)) {
            Matcher matcher = Pattern.compile("^(\\s*)print\\s+(.+?)\\s*$").matcher(line);
            return matcher.matches() ? matcher.group(1) + "print(" + matcher.group(2) + ")" : null;
        }
        if ("semicolon".equals(issue.fix)) {
            String[] parts = splitLineComment(line);
            String code = parts[0].replaceFirst("\\s+$", "");
            return code.endsWith(";") ? null : code + ";" + parts[1];
        }
        if ("yaml_tabs".equals(issue.fix)) {
            Matcher matcher = Pattern.compile("^\\t+").matcher(line);
            if (matcher.find()) {
                String spaces = matcher.group().replace("\t", "    ");
                return spaces + line.substring(matcher.end());
            }
            return null;
        }
        if ("rename_class".equals(issue.fix) && issue.data != null) {
            return line.replaceFirst("\\bpublic\\s+class\\s+[A-Za-z_$][A-Za-z0-9_$]*",
                    "public class " + issue.data);
        }
        return null;
    }

    private String[] splitLineComment(String line) {
        String marker = currentLanguage == null ? "" : currentLanguage.lineComment;
        if (marker == null || marker.length() == 0) return new String[]{line, ""};
        int idx = line.indexOf(marker);
        if (idx < 0) return new String[]{line, ""};
        return new String[]{line.substring(0, idx), "  " + line.substring(idx)};
    }

    private String joinLines(String[] lines) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < lines.length; i++) {
            if (i > 0) sb.append('\n');
            sb.append(lines[i]);
        }
        return sb.toString();
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

    private void goToLine(final int line) {
        int targetLine = Math.max(1, Math.min(line, editor.getLineCount()));
        String text = editor.getText().toString();
        int offset = 0;
        int current = 1;
        while (offset < text.length() && current < targetLine) {
            if (text.charAt(offset++) == '\n') current++;
        }
        final int selection = Math.min(offset, editor.length());
        editor.requestFocus();
        editor.setSelection(selection);
        editor.post(new Runnable() {
            @Override public void run() {
                android.text.Layout layout = editor.getLayout();
                if (layout != null) {
                    int lineIndex = Math.max(0, Math.min(line - 1, layout.getLineCount() - 1));
                    editor.scrollTo(editor.getScrollX(), Math.max(0, layout.getLineTop(lineIndex)));
                }
            }
        });
        updateStatus("Line " + targetLine, ACCENT);
    }

    private List<OutlineItem> buildOutline(String text) {
        List<OutlineItem> items = new ArrayList<>();
        String id = currentLanguage == null ? "text" : currentLanguage.id;
        String[] lines = text.split("\n", -1);
        for (int i = 0; i < lines.length && items.size() < 600; i++) {
            String line = lines[i];
            String trimmed = line.trim();
            if (trimmed.length() == 0 || (!"markdown".equals(id) && trimmed.startsWith("#")) || trimmed.startsWith("//")
                    || trimmed.startsWith("/*") || trimmed.startsWith("*") || trimmed.startsWith("--")) {
                continue;
            }
            int level = outlineLevel(line);
            Matcher matcher = null;
            if ("python".equals(id)) {
                matcher = Pattern.compile("^\\s*(async\\s+def|def|class)\\s+([A-Za-z_]\\w*)").matcher(line);
                if (matcher.find()) {
                    items.add(new OutlineItem(i + 1, level, matcher.group(1), matcher.group(2)));
                    continue;
                }
            } else if ("markdown".equals(id)) {
                matcher = Pattern.compile("^(#{1,6})\\s+(.+?)\\s*#*\\s*$").matcher(line);
                if (matcher.find()) {
                    items.add(new OutlineItem(i + 1, matcher.group(1).length() - 1, "heading", matcher.group(2)));
                    continue;
                }
            } else if ("html".equals(id)) {
                matcher = Pattern.compile("^\\s*<\\s*(h[1-6]|section|article|main|nav|div)\\b([^>]*)>", Pattern.CASE_INSENSITIVE).matcher(line);
                if (matcher.find()) {
                    String name = matcher.group(1).toLowerCase(Locale.US);
                    Matcher ident = Pattern.compile("\\b(?:id|class)\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]").matcher(matcher.group(2));
                    if (ident.find()) name += " #" + ident.group(1);
                    items.add(new OutlineItem(i + 1, level, "tag", name));
                    continue;
                }
            } else if ("css".equals(id) && trimmed.endsWith("{")) {
                items.add(new OutlineItem(i + 1, level, "rule", trimmed.substring(0, trimmed.length() - 1).trim()));
                continue;
            } else if ("sql".equals(id)) {
                matcher = Pattern.compile("^\\s*create\\s+(table|view|index|trigger|function|procedure)\\s+([A-Za-z_][\\w.]*)", Pattern.CASE_INSENSITIVE).matcher(line);
                if (matcher.find()) {
                    items.add(new OutlineItem(i + 1, level, matcher.group(1).toLowerCase(Locale.US), matcher.group(2)));
                    continue;
                }
            }

            matcher = Pattern.compile("^\\s*(?:export\\s+|public\\s+|private\\s+|protected\\s+|internal\\s+|open\\s+|final\\s+|abstract\\s+|sealed\\s+|data\\s+|static\\s+)*(class|interface|enum|struct|record|object|trait)\\s+([A-Za-z_$][\\w$]*)").matcher(line);
            if (matcher.find()) {
                items.add(new OutlineItem(i + 1, level, matcher.group(1), matcher.group(2)));
                continue;
            }
            matcher = Pattern.compile("^\\s*(?:export\\s+|async\\s+|suspend\\s+|static\\s+)*(func|fun|function|def|fn)\\s+(?:\\([^)]*\\)\\s*)?([A-Za-z_$][\\w$]*)").matcher(line);
            if (matcher.find()) {
                items.add(new OutlineItem(i + 1, level, matcher.group(1), matcher.group(2)));
                continue;
            }
            if (Arrays.asList("c", "cpp", "java", "csharp", "go", "rust", "swift", "kotlin").contains(id)) {
                matcher = Pattern.compile("^\\s*(?:[A-Za-z_$][\\w$<>\\[\\],.?*&:\\s]+\\s+)+([A-Za-z_$][\\w$]*)\\s*\\([^;{}]*\\)\\s*(?:\\{|=>)?\\s*$").matcher(line);
                if (matcher.find()) {
                    String name = matcher.group(1);
                    if (!Arrays.asList("if", "for", "while", "switch", "catch").contains(name)) {
                        items.add(new OutlineItem(i + 1, level, "method", name));
                    }
                }
            }
        }
        return items;
    }

    private int outlineLevel(String line) {
        int width = 0;
        for (int i = 0; i < line.length(); i++) {
            char ch = line.charAt(i);
            if (ch == ' ') width++;
            else if (ch == '\t') width += 4;
            else break;
        }
        return Math.min(8, width / 4);
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

    private void addLanguageChecks(String text, String[] lines, List<CheckIssue> issues) {
        if (isLang("json")) checkJson(text, issues);
        if (isLang("html")) checkHtml(text, issues);
        if (isLang("java")) checkJava(text, issues);
        if (isLang("shell")) checkShell(lines, issues);
    }

    private void checkJson(String text, List<CheckIssue> issues) {
        try {
            JSONTokener tokener = new JSONTokener(text);
            tokener.nextValue();
            if (tokener.nextClean() != 0) {
                addIssue(issues, 1, "JSON has extra data after the first value", null, null);
            }
        } catch (Exception ex) {
            addIssue(issues, 1, "JSON parse error: " + ex.getMessage(), null, null);
        }
    }

    private void checkHtml(String text, List<CheckIssue> issues) {
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
                addIssue(issues, lineForOffset(text, matcher.start()), "HTML closing tag without opener: </" + tag + ">", null, null);
            } else {
                String open = stack.pop();
                if (!open.equals(tag)) {
                    addIssue(issues, lineForOffset(text, matcher.start()), "HTML tag mismatch: expected </" + open + "> before </" + tag + ">", null, null);
                }
            }
        }
        if (!stack.isEmpty()) {
            String tag = stack.peek();
            addIssue(issues, text.split("\n", -1).length, "HTML unclosed tag: <" + tag + ">", "append_eof", "</" + tag + ">");
        }
    }

    private void checkJava(String text, List<CheckIssue> issues) {
        if (currentName == null || !currentName.endsWith(".java")) return;
        Matcher matcher = Pattern.compile("\\bpublic\\s+class\\s+([A-Za-z_$][A-Za-z0-9_$]*)").matcher(text);
        if (matcher.find()) {
            String expected = currentName.substring(0, currentName.length() - 5);
            if (!expected.equals(matcher.group(1))) {
                addIssue(issues, lineForOffset(text, matcher.start(1)), "Java public class should match file name: " + expected, "rename_class", expected);
            }
        }
    }

    private void checkShell(String[] lines, List<CheckIssue> issues) {
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
        if (ifs > 0) addIssue(issues, lines.length, "shell block may be missing 'fi'", "append_eof", repeatWord("fi", ifs));
        if (dos > 0) addIssue(issues, lines.length, "shell loop may be missing 'done'", "append_eof", repeatWord("done", dos));
        if (cases > 0) addIssue(issues, lines.length, "shell case may be missing 'esac'", "append_eof", repeatWord("esac", cases));
    }

    private int lineForOffset(String text, int offset) {
        int line = 1;
        for (int i = 0; i < Math.min(offset, text.length()); i++) {
            if (text.charAt(i) == '\n') line++;
        }
        return line;
    }

    private String repeatWord(String word, int count) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < count; i++) {
            sb.append(word).append('\n');
        }
        return sb.toString();
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

    private static class CheckIssue {
        final int line;
        final String message;
        final String fix;
        final String data;

        CheckIssue(int line, String message, String fix, String data) {
            this.line = line;
            this.message = message;
            this.fix = fix;
            this.data = data;
        }
    }

    private static class OutlineItem {
        final int line;
        final int level;
        final String kind;
        final String name;

        OutlineItem(int line, int level, String kind, String name) {
            this.line = line;
            this.level = level;
            this.kind = kind == null ? "" : kind;
            this.name = name == null ? "" : name;
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
