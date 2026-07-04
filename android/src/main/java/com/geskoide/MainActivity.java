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
import android.text.Editable;
import android.text.Spannable;
import android.text.TextPaint;
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

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
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

    private static final Set<String> KEYWORDS = new HashSet<>(Arrays.asList(
            "and", "as", "assert", "async", "await", "break", "case", "catch", "class",
            "const", "continue", "def", "default", "delete", "do", "elif", "else", "except",
            "export", "extends", "false", "finally", "for", "from", "function", "global",
            "if", "import", "in", "interface", "is", "lambda", "let", "match", "new",
            "nonlocal", "not", "null", "or", "pass", "private", "public", "raise", "return",
            "static", "super", "switch", "this", "throw", "true", "try", "type", "var",
            "void", "while", "with", "yield"
    ));

    private static final Set<String> BUILTINS = new HashSet<>(Arrays.asList(
            "print", "len", "range", "open", "input", "int", "float", "str", "bool",
            "list", "dict", "set", "tuple", "console", "log", "document", "window",
            "Math", "JSON", "Array", "Object", "String", "Number", "Boolean", "Map", "Set"
    ));

    private final Handler handler = new Handler(Looper.getMainLooper());
    private CodeEditor editor;
    private TextView status;
    private TextView output;
    private TextView pathLabel;
    private Uri currentUri;
    private String currentName = "untitled.py";
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
        addButton(tools, "Run", new View.OnClickListener() {
            @Override public void onClick(View v) { runChecks(); }
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
                "def main():\n" +
                "    print(\"Hello from GeskoIDE on Android\")\n\n" +
                "if __name__ == \"__main__\":\n" +
                "    main()\n");
        dirty = false;
        updateStatus("Ready", ACCENT);
        output.setText("GeskoIDE Android Edition\nOffline editor with Gecko Dark colors.");
    }

    private void showTemplateMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add("Python");
        menu.getMenu().add("JavaScript");
        menu.getMenu().add("HTML");
        menu.getMenu().add("Plain Text");
        menu.setOnMenuItemClickListener(new PopupMenu.OnMenuItemClickListener() {
            @Override public boolean onMenuItemClick(MenuItem item) {
                String choice = item.getTitle().toString();
                if ("Python".equals(choice)) {
                    setDocument("untitled.py", "def main():\n    \n\nif __name__ == \"__main__\":\n    main()\n");
                } else if ("JavaScript".equals(choice)) {
                    setDocument("untitled.js", "function main() {\n  console.log(\"Hello from GeskoIDE\");\n}\n\nmain();\n");
                } else if ("HTML".equals(choice)) {
                    setDocument("untitled.html", "<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <title>GeskoIDE</title>\n</head>\n<body>\n  <h1>Hello</h1>\n</body>\n</html>\n");
                } else {
                    setDocument("untitled.txt", "");
                }
                currentUri = null;
                dirty = false;
                output.setText("");
                updateStatus("New file", ACCENT);
                showKeyboard();
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
        highlighting = true;
        editor.setText(text);
        editor.setSelection(Math.min(editor.length(), Math.max(0, text.indexOf("\n") + 1)));
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

    private void quickFix() {
        String text = editor.getText().toString();
        String fixed = text
                .replaceAll("(?m)^(\\s*(if|elif|else|for|while|def|class|try|except|finally|with)\\b[^:\\n]*)$", "$1:")
                .replace("print \"", "print(\"")
                .replace("print '", "print('");
        if (!fixed.equals(text)) {
            editor.setText(fixed);
            editor.setSelection(Math.min(fixed.length(), editor.getSelectionStart()));
            dirty = true;
            updateStatus("Fixed", ACCENT);
            runChecks();
        } else {
            updateStatus("Nothing to fix", DIM);
        }
    }

    private void runChecks() {
        String text = editor.getText().toString();
        List<String> issues = new ArrayList<>();
        String[] lines = text.split("\n", -1);
        int parens = 0;
        int braces = 0;
        int brackets = 0;
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = line.trim();
            if (trimmed.startsWith("if ") || trimmed.startsWith("for ") || trimmed.startsWith("while ")
                    || trimmed.startsWith("def ") || trimmed.startsWith("class ") || trimmed.startsWith("else")
                    || trimmed.startsWith("elif ") || trimmed.startsWith("try") || trimmed.startsWith("except")
                    || trimmed.startsWith("finally") || trimmed.startsWith("with ")) {
                if (!trimmed.endsWith(":") && currentName.endsWith(".py")) {
                    issues.add("line " + (i + 1) + ": missing ':'");
                }
            }
            if (trimmed.startsWith("print ") && !trimmed.startsWith("print(") && currentName.endsWith(".py")) {
                issues.add("line " + (i + 1) + ": Python 2 style print");
            }
            for (int j = 0; j < line.length(); j++) {
                char ch = line.charAt(j);
                if (ch == '(') parens++;
                if (ch == ')') parens--;
                if (ch == '{') braces++;
                if (ch == '}') braces--;
                if (ch == '[') brackets++;
                if (ch == ']') brackets--;
            }
        }
        if (parens != 0) issues.add("unbalanced parentheses");
        if (braces != 0) issues.add("unbalanced braces");
        if (brackets != 0) issues.add("unbalanced brackets");

        if (issues.isEmpty()) {
            output.setText("No obvious issues found.\nAndroid edition checks syntax patterns locally.");
            updateStatus("Clean", ACCENT);
        } else {
            StringBuilder sb = new StringBuilder();
            for (String issue : issues) sb.append(issue).append('\n');
            output.setText(sb.toString());
            updateStatus(issues.size() + " issue" + (issues.size() == 1 ? "" : "s"), WARN);
        }
    }

    private void highlight() {
        Editable text = editor.getText();
        highlighting = true;
        ForegroundColorSpan[] old = text.getSpans(0, text.length(), ForegroundColorSpan.class);
        for (ForegroundColorSpan span : old) {
            text.removeSpan(span);
        }
        applyRegex(text, "\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*'", STRING);
        applyRegex(text, "(?m)#.*$|//.*$", COMMENT);
        applyRegex(text, "\\b\\d+(?:\\.\\d+)?\\b", NUMBER);
        applyRegex(text, "[(){}\\[\\]]", BRACKET);
        applyRegex(text, "[+\\-*/%=!<>|&]+", OP);

        Matcher word = Pattern.compile("\\b[A-Za-z_][A-Za-z0-9_]*\\b").matcher(text);
        while (word.find()) {
            String token = word.group();
            if (KEYWORDS.contains(token)) {
                text.setSpan(new ForegroundColorSpan(KW), word.start(), word.end(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (BUILTINS.contains(token)) {
                text.setSpan(new ForegroundColorSpan(BUILTIN), word.start(), word.end(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
        }
        highlighting = false;
        updatePathLabel();
        editor.invalidate();
    }

    private void applyRegex(Editable text, String regex, int color) {
        Matcher matcher = Pattern.compile(regex).matcher(text);
        while (matcher.find()) {
            text.setSpan(new ForegroundColorSpan(color), matcher.start(), matcher.end(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
    }

    private void updatePathLabel() {
        String mark = dirty ? " *" : "";
        String uriText = currentUri == null ? "local draft" : currentUri.toString();
        pathLabel.setText(currentName + mark + "  -  " + uriText);
    }

    private void updateStatus(String message, int color) {
        int lines = editor == null ? 0 : editor.getLineCount();
        int chars = editor == null ? 0 : editor.length();
        status.setText(String.format(Locale.US, "%s   lines %d   chars %d", message, lines, chars));
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
