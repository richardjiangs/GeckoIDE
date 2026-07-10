#!/bin/sh
''''command -v python3 >/dev/null 2>&1 && exec python3 "$0" "$@" # '''
''''echo "GeskoIDE needs Python 3. On macOS run:  xcode-select --install   (free, one time) or install Python 3 from python.org, then open GeskoIDE.command again." >&2; exit 127 # '''
"""
GeskoIDE - a fast, friendly, fully offline code editor for macOS (and Linux/Windows).

This single file is simultaneously a valid POSIX shell script and a Python 3
program: double-clicking GeskoIDE.command on macOS opens Terminal, the two
shell lines above hand the file to the system's python3, and the rest of the
file is the whole application.

Design goals
  * Zero dependencies: Python 3.8+ standard library only (tkinter for the UI).
  * Zero network: no APIs, no telemetry, no downloads. Everything is local.
  * Friendly: welcome screen, skeleton templates for new files, automatic
    hints while typing, Tab auto-complete / auto-fix, one-key Run and Debug.
  * Original look: the "Gecko Dark" color theme is designed from scratch for
    GeskoIDE (it is not a copy of any other editor's licensed theme).

Command line:
  GeskoIDE.command [files...]     open files
  GeskoIDE.command --selftest     run the built-in test suite (no GUI needed)
  GeskoIDE.command --version      print version
"""

import ast
import builtins as _builtins
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import queue as _queue
import webbrowser
from bisect import bisect_right
from collections import Counter, namedtuple

APP = "GeskoIDE"
VERSION = "2.3.0"
IS_MAC = (sys.platform == "darwin")
IS_WIN = (sys.platform == "win32")

# Silence the "system Tk is deprecated" banner from Apple's bundled Tk 8.5.
os.environ.setdefault("TK_SILENCE_DEPRECATION", "1")


def augment_path():
    """Make sure common tool locations are on PATH (Homebrew, /usr/local)."""
    extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin",
             os.path.expanduser("~/.cargo/bin"), "/usr/bin", "/bin"]
    parts = os.environ.get("PATH", "").split(os.pathsep)
    for p in extra:
        if os.path.isdir(p) and p not in parts:
            parts.append(p)
    os.environ["PATH"] = os.pathsep.join(parts)


augment_path()


def settings_dir():
    if IS_MAC:
        d = os.path.expanduser("~/Library/Application Support/GeskoIDE")
    elif IS_WIN:
        d = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "GeskoIDE")
    else:
        d = os.path.join(os.environ.get("XDG_CONFIG_HOME",
                                        os.path.expanduser("~/.config")), "geskoide")
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        d = tempfile.gettempdir()
    return d


def _log_error(where, exc):
    """Append an unexpected error to a local log so problems are diagnosable
    (still 100% offline - it just writes a file next to the settings)."""
    import traceback
    try:
        with open(os.path.join(settings_dir(), "error.log"), "a",
                  encoding="utf-8") as f:
            f.write("[%s] %s\n%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"),
                                       where, traceback.format_exc()))
    except Exception:
        pass


# --------------------------------------------------------------------------
# Theme: "Gecko Dark" - an original palette made for GeskoIDE.
# --------------------------------------------------------------------------

THEME = {
    "bg":           "#0f1512",   # window chrome
    "bg_panel":     "#131b17",   # side panels / bars
    "bg_editor":    "#0e1411",   # text area
    "bg_gutter":    "#0c110f",   # line-number gutter
    "bg_status":    "#18231d",   # status bar
    "bg_hover":     "#1d2a23",
    "bg_active":    "#24352c",
    "bg_input":     "#16201b",
    "border":       "#233129",
    "fg":           "#d7e3db",
    "fg_dim":       "#7f9187",
    "fg_faint":     "#54655c",
    "accent":       "#3fd68f",   # gecko green
    "accent_dark":  "#2a9463",
    "caret":        "#3fd68f",
    "sel":          "#2b5140",
    "current_line": "#151f19",
    "find_match":   "#3d5a2a",
    "brk_match":    "#3a5a4a",
    "error":        "#ff6b6b",
    "warn":         "#ffc857",
    "info":         "#6fb7ff",
    "ok":           "#3fd68f",
}

# Every token class gets its own color, so literally every word on screen is
# colored. (Original palette - not derived from any other editor.)
TOKEN_COLORS = {
    "keyword":   "#45d38a",
    "type":      "#58c7d8",
    "builtin":   "#6cb8e8",
    "func":      "#bcd96c",
    "cls":       "#e8c766",
    "const":     "#f08fb1",
    "string":    "#e6a06c",
    "number":    "#d99fe8",
    "comment":   "#5f7566",
    "decorator": "#e07a5f",
    "preproc":   "#e07a5f",
    "op":        "#7fd8c0",
    "punct":     "#95a89c",
    "ident":     "#d7e3db",
    "var":       "#9fd0b5",
    "brk0":      "#e0b458",
    "brk1":      "#c17ee0",
    "brk2":      "#5fb7e8",
    # Markdown / prose extras
    "heading":   "#45d38a",
    "bold":      "#e8c766",
    "italic":    "#9fd0b5",
    "link":      "#6cb8e8",
    "codeblock": "#e6a06c",
}
TOKEN_BOLD = {"keyword", "heading", "bold", "cls"}
TOKEN_ITALIC = {"comment", "italic", "decorator"}


# --------------------------------------------------------------------------
# Language definitions
# --------------------------------------------------------------------------

def _lang(name, exts, **kw):
    d = dict(
        name=name, exts=exts,
        line_comment=None,          # e.g. "#"
        block_comment=None,         # e.g. ("/*", "*/")
        strings="\"'",              # quote characters
        triple=False,               # python-style triple quotes
        backtick=False,             # js template strings
        str_prefix=False,           # python r"" f"" prefixes
        keywords="", types="", builtins="", constants="",
        preproc=None,               # regex for preprocessor lines
        decorator=None,             # regex for decorators / annotations
        extra=(),                   # [(token_type, regex), ...] highest priority
        ci=False,                   # case-insensitive keywords
        indent=4, indent_char=" ",
        family=None,                # snippet family (defaults to language id)
        run=None,                   # runner id (defaults to language id)
    )
    d.update(kw)
    for k in ("keywords", "types", "builtins", "constants"):
        d[k] = set(d[k].split())
    return d


LANGS = {}

LANGS["python"] = _lang(
    "Python", [".py", ".pyw"],
    line_comment="#", triple=True, str_prefix=True,
    decorator=r"^[ \t]*@[\w.]+",
    keywords="and as assert async await break class continue def del elif else"
             " except finally for from global if import in is lambda match case"
             " nonlocal not or pass raise return try while with yield",
    constants="True False None Ellipsis NotImplemented __name__ __main__ __file__ __doc__",
    builtins="print len range open input int float str bool list dict set tuple"
             " type isinstance issubclass super object enumerate zip map filter"
             " sorted reversed sum min max abs round divmod pow any all repr"
             " format vars dir id hash iter next getattr setattr hasattr delattr"
             " callable staticmethod classmethod property exec eval compile"
             " globals locals bytes bytearray frozenset complex ord chr hex oct"
             " bin slice breakpoint exit quit self cls",
    types="Exception BaseException ValueError TypeError KeyError IndexError"
          " RuntimeError StopIteration OSError IOError AttributeError NameError"
          " ZeroDivisionError ArithmeticError NotImplementedError ImportError"
          " ModuleNotFoundError FileNotFoundError PermissionError TimeoutError"
          " UnicodeError OverflowError RecursionError SyntaxError IndentationError"
          " KeyboardInterrupt SystemExit List Dict Set Tuple Optional Union Any"
          " Callable Iterable Iterator Sequence Mapping",
)

LANGS["javascript"] = _lang(
    "JavaScript", [".js", ".mjs", ".cjs", ".jsx"],
    line_comment="//", block_comment=("/*", "*/"), backtick=True,
    decorator=r"@\w+", indent=2,
    keywords="break case catch class const continue debugger default delete do"
             " else export extends finally for function if import in instanceof"
             " let new of return static super switch this throw try typeof var"
             " void while with yield async await get set",
    constants="true false null undefined NaN Infinity globalThis",
    types="Array Object String Number Boolean Symbol BigInt Map Set WeakMap"
          " WeakSet Date RegExp Promise Error TypeError RangeError SyntaxError"
          " JSON Math Proxy Reflect Intl",
    builtins="console log warn error info document window parseInt parseFloat"
             " isNaN isFinite alert prompt confirm setTimeout setInterval"
             " clearTimeout clearInterval fetch require module exports process"
             " structuredClone queueMicrotask encodeURIComponent decodeURIComponent",
    family="clike", run="node",
)

LANGS["typescript"] = _lang(
    "TypeScript", [".ts", ".tsx", ".mts", ".cts"],
    line_comment="//", block_comment=("/*", "*/"), backtick=True,
    decorator=r"@\w+", indent=2,
    keywords=LANGS["javascript"]["keywords"] and
             "break case catch class const continue debugger default delete do"
             " else export extends finally for function if import in instanceof"
             " let new of return static super switch this throw try typeof var"
             " void while with yield async await get set type interface enum"
             " namespace declare readonly abstract implements private public"
             " protected keyof infer satisfies override as is module",
    constants="true false null undefined NaN Infinity globalThis",
    types="string number boolean object symbol bigint void never unknown any"
          " Array Object String Number Boolean Map Set Date RegExp Promise Error"
          " Record Partial Required Readonly Pick Omit Exclude Extract"
          " ReturnType Parameters Awaited JSON Math",
    builtins=LANGS["javascript"]["builtins"] and
             "console log warn error info document window parseInt parseFloat"
             " isNaN isFinite alert prompt confirm setTimeout setInterval"
             " clearTimeout clearInterval fetch require module exports process",
    family="clike", run="typescript",
)

LANGS["html"] = _lang(
    "HTML", [".html", ".htm", ".xhtml"],
    block_comment=("<!--", "-->"), indent=2,
    extra=(
        ("preproc", r"<![A-Za-z][^>]*>"),
        ("keyword", r"</?[A-Za-z][A-Za-z0-9-]*|/?>"),
        ("type", r"\b[a-zA-Z-]+(?=[ \t]*=)"),
        ("const", r"&#?[a-zA-Z0-9]+;"),
    ),
    family="html", run="html",
)

LANGS["css"] = _lang(
    "CSS", [".css", ".scss", ".less"],
    block_comment=("/*", "*/"), indent=2,
    extra=(
        ("decorator", r"@[\w-]+"),
        ("number", r"#[0-9a-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|vh|vw|vmin|vmax|%|s|ms|fr|deg|pt|ch|ex)\b"),
        ("func", r"[\w-]+(?=\()"),
        ("builtin", r"[\w-]+(?=[ \t]*:)"),
        ("type", r"[.#][\w-]+"),
        ("const", r"!important\b"),
    ),
    family="css", run="css",
)

LANGS["json"] = _lang(
    "JSON", [".json", ".jsonc", ".geojson"],
    line_comment="//", indent=2,
    constants="true false null",
    family="json", run="json",
)

LANGS["markdown"] = _lang(
    "Markdown", [".md", ".markdown"],
    strings="", indent=2,
    extra=(
        ("codeblock", r"(?s:^```.*?(?:^```[ \t]*$|\Z))"),
        ("string", r"`[^`\n]+`"),
        ("heading", r"^#{1,6}[^\n]*$"),
        ("bold", r"\*\*[^*\n]+\*\*|__[^_\n]+__"),
        ("italic", r"\*[^*\n]+\*|\b_[^_\n]+_\b"),
        ("link", r"!?\[[^\]\n]*\]\([^)\n]*\)|<https?://[^>\n]+>"),
        ("keyword", r"^[ \t]*(?:[-*+]|\d+\.)[ \t]"),
        ("comment", r"^>[^\n]*$"),
        ("op", r"^(?:---+|\*\*\*+|===+)[ \t]*$"),
    ),
    family="markdown", run="markdown",
)

LANGS["c"] = _lang(
    "C", [".c", ".h"],
    line_comment="//", block_comment=("/*", "*/"),
    preproc=r"^[ \t]*#[ \t]*\w+",
    keywords="auto break case const continue default do else enum extern for"
             " goto if inline register restrict return sizeof static struct"
             " switch typedef union volatile while",
    types="char double float int long short signed unsigned void _Bool bool"
          " size_t ssize_t wchar_t FILE va_list int8_t int16_t int32_t int64_t"
          " uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t ptrdiff_t",
    constants="NULL EOF stdin stdout stderr true false INT_MAX INT_MIN SIZE_MAX",
    builtins="printf scanf fprintf sprintf snprintf malloc calloc realloc free"
             " memcpy memmove memset strlen strcpy strncpy strcmp strncmp strcat"
             " strchr strstr fopen fclose fread fwrite fgets fputs puts putchar"
             " getchar exit abort assert perror qsort bsearch atoi atof strtol"
             " strtod rand srand time main",
    family="clike", run="c",
)

LANGS["cpp"] = _lang(
    "C++", [".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"],
    line_comment="//", block_comment=("/*", "*/"),
    preproc=r"^[ \t]*#[ \t]*\w+",
    keywords="alignas alignof asm auto break case catch class concept const"
             " consteval constexpr constinit const_cast continue decltype"
             " default delete do dynamic_cast else enum explicit export extern"
             " final for friend goto if inline mutable namespace new noexcept"
             " operator override private protected public reinterpret_cast"
             " requires return sizeof static static_assert static_cast struct"
             " switch template this thread_local throw try typedef typeid"
             " typename union using virtual volatile while co_await co_return"
             " co_yield",
    types="bool char char8_t char16_t char32_t double float int long short"
          " signed unsigned void wchar_t size_t string wstring string_view"
          " vector map set unordered_map unordered_set list deque array pair"
          " tuple shared_ptr unique_ptr weak_ptr optional variant any function"
          " iostream istream ostream stringstream span",
    constants="NULL nullptr true false EOF stdin stdout stderr npos",
    builtins="std cout cin cerr clog endl flush getline make_shared make_unique"
             " make_pair make_tuple move forward swap sort stable_sort find"
             " find_if count count_if for_each transform accumulate min max"
             " min_element max_element reverse unique lower_bound upper_bound"
             " begin end rbegin rend push_back pop_back emplace emplace_back"
             " size length empty clear insert erase at front back top push pop"
             " get first second to_string stoi stol stod substr c_str data"
             " printf scanf fprintf sprintf snprintf puts putchar getchar malloc"
             " calloc realloc free memcpy memset strlen strcmp strcpy fopen"
             " fclose exit abort assert main",
    family="clike", run="cpp",
)

LANGS["csharp"] = _lang(
    "C#", [".cs"],
    line_comment="//", block_comment=("/*", "*/"),
    decorator=r"^[ \t]*\[[\w.()\", =]+\]",
    keywords="abstract as base break case catch checked class const continue"
             " default delegate do else enum event explicit extern finally"
             " fixed for foreach goto if implicit in interface internal is lock"
             " namespace new operator out override params private protected"
             " public readonly ref return sealed sizeof stackalloc static"
             " struct switch this throw try typeof unchecked unsafe using var"
             " virtual void volatile while async await record init required get set",
    types="bool byte char decimal double float int long object sbyte short"
          " string uint ulong ushort String Int32 Int64 Double Boolean List"
          " Dictionary Task Action Func Console Object Exception DateTime"
          " TimeSpan Guid IEnumerable",
    constants="true false null",
    builtins="WriteLine Write ReadLine Parse ToString Length Count Add Remove"
             " Contains Select Where First Last OrderBy Main",
    family="clike", run="csharp",
)

LANGS["java"] = _lang(
    "Java", [".java"],
    line_comment="//", block_comment=("/*", "*/"),
    decorator=r"@\w+",
    keywords="abstract assert break case catch class const continue default do"
             " else enum extends final finally for goto if implements import"
             " instanceof interface native new package private protected public"
             " return static strictfp super switch synchronized this throw"
             " throws transient try void volatile while record sealed permits"
             " var yield",
    types="boolean byte char double float int long short String Integer Long"
          " Double Float Boolean Character Byte Short Object List ArrayList Map"
          " HashMap Set HashSet Optional Stream Exception RuntimeException"
          " Thread Runnable StringBuilder Scanner Math System",
    constants="true false null",
    builtins="println print printf out err main toString equals hashCode"
             " length size get put add remove contains valueOf parseInt format",
    family="clike", run="java",
)

LANGS["go"] = _lang(
    "Go", [".go"],
    line_comment="//", block_comment=("/*", "*/"), backtick=True,
    indent=4, indent_char="\t",
    keywords="break case chan const continue default defer else fallthrough"
             " for func go goto if import interface map package range return"
             " select struct switch type var",
    types="bool byte complex64 complex128 error float32 float64 int int8 int16"
          " int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any"
          " comparable",
    constants="true false nil iota",
    builtins="append cap close copy delete imag len make new panic print"
             " println real recover fmt Println Printf Sprintf Errorf main",
    family="clike", run="go",
)

LANGS["rust"] = _lang(
    "Rust", [".rs"],
    line_comment="//", block_comment=("/*", "*/"),
    decorator=r"#!?\[[^\]\n]*\]",
    keywords="as async await break const continue crate dyn else enum extern"
             " fn for if impl in let loop match mod move mut pub ref return"
             " self Self static struct super trait type union unsafe use where"
             " while",
    types="bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128"
          " usize String Vec Option Result Box Rc Arc RefCell HashMap HashSet"
          " BTreeMap Cow PathBuf Path",
    constants="true false Some None Ok Err",
    builtins="println print format vec panic assert assert_eq dbg todo"
             " unimplemented unwrap expect iter collect map filter push pop len"
             " clone into from new default main",
    family="clike", run="rust",
)

LANGS["ruby"] = _lang(
    "Ruby", [".rb", ".rake", ".gemspec"],
    line_comment="#", indent=2,
    extra=(("comment", r"(?ms:^=begin.*?^=end[ \t]*$)"),
           ("const", r"(?m::\w+)"),
           ("var", r"[@$]{1,2}\w+")),
    keywords="BEGIN END alias and begin break case class def do else elsif end"
             " ensure for if in module next not or redo rescue retry return"
             " self super then undef unless until when while yield require"
             " require_relative include extend raise lambda proc loop"
             " attr_accessor attr_reader attr_writer defined",
    constants="true false nil __FILE__ __LINE__ ARGV ENV",
    builtins="puts print p gets chomp to_s to_i to_f to_sym map each select"
             " reject reduce inject times upto downto push pop length size new"
             " inspect freeze dup call join split first last sort reverse",
    family="ruby", run="ruby",
)

LANGS["php"] = _lang(
    "PHP", [".php"],
    line_comment="//", block_comment=("/*", "*/"),
    extra=(("var", r"\$\w+"), ("preproc", r"<\?php|\?>"), ("decorator", r"#\[[^\]\n]*\]")),
    keywords="abstract and array as break callable case catch class clone const"
             " continue declare default do echo else elseif empty enum extends"
             " final finally fn for foreach function global goto if implements"
             " include include_once instanceof insteadof interface isset list"
             " match namespace new or print private protected public readonly"
             " require require_once return static switch throw trait try unset"
             " use var while xor yield",
    constants="true false null TRUE FALSE NULL PHP_EOL __DIR__ __FILE__",
    types="int float string bool object mixed void iterable self parent",
    builtins="strlen count array_map array_filter array_merge array_keys"
             " array_values implode explode str_replace substr sprintf printf"
             " var_dump print_r json_encode json_decode file_get_contents"
             " file_put_contents preg_match preg_replace in_array is_array"
             " is_string is_int die exit",
    family="clike", run="php",
)

LANGS["shell"] = _lang(
    "Shell", [".sh", ".bash", ".zsh", ".command"],
    line_comment="#", indent=2,
    extra=(("var", r"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*!$-]"),),
    keywords="if then else elif fi for while until do done case esac in"
             " function select time break continue return exit export local"
             " readonly declare typeset set unset shift trap source alias eval"
             " exec wait",
    builtins="echo printf read cd pwd ls cp mv rm mkdir rmdir touch cat grep"
             " sed awk cut sort uniq head tail tr wc find xargs which test kill"
             " jobs fg bg sleep date basename dirname chmod chown curl tar env"
             " sudo tee open pbcopy pbpaste osascript brew git python3 pip3",
    constants="true false",
    family="shell", run="shell",
)

LANGS["swift"] = _lang(
    "Swift", [".swift"],
    line_comment="//", block_comment=("/*", "*/"),
    decorator=r"@\w+",
    keywords="associatedtype class deinit enum extension fileprivate func"
             " import init inout internal let open operator private protocol"
             " public rethrows static struct subscript typealias var break case"
             " continue default defer do else fallthrough for guard if in"
             " repeat return switch where while as catch is throw throws try"
             " await async actor some any lazy weak unowned mutating override"
             " required convenience final indirect",
    types="Int Int8 Int16 Int32 Int64 UInt Double Float Bool String Character"
          " Array Dictionary Set Optional Any AnyObject Void Error Result Data"
          " URL Date Range ClosedRange",
    constants="true false nil self Self super",
    builtins="print debugPrint dump min max abs map filter reduce compactMap"
             " flatMap sorted count append insert remove contains isEmpty first"
             " last joined split hasPrefix hasSuffix readLine",
    family="clike", run="swift",
)

LANGS["kotlin"] = _lang(
    "Kotlin", [".kt", ".kts"],
    line_comment="//", block_comment=("/*", "*/"),
    decorator=r"@\w+",
    keywords="as break class continue do else for fun if in interface is"
             " object package return super this throw try typealias val var"
             " when while by catch constructor delegate finally get import init"
             " set where abstract annotation companion const data enum final"
             " infix inline inner internal lateinit open operator out override"
             " private protected public reified sealed suspend vararg",
    types="Int Long Short Byte Double Float Boolean Char String Unit Any"
          " Nothing List MutableList Map MutableMap Set MutableSet Array"
          " IntArray Pair Triple Sequence",
    constants="true false null",
    builtins="println print listOf mutableListOf mapOf mutableMapOf setOf"
             " arrayOf let also apply run with takeIf takeUnless lazy require"
             " check error TODO toString map filter forEach first last main",
    family="clike", run="kotlin",
)

LANGS["lua"] = _lang(
    "Lua", [".lua"],
    line_comment="--", block_comment=("--[[", "]]"), indent=2,
    keywords="and break do else elseif end for function goto if in local not"
             " or repeat return then until while",
    constants="true false nil _G self",
    builtins="print pairs ipairs next type tostring tonumber pcall xpcall"
             " error assert select unpack require setmetatable getmetatable"
             " rawget rawset string table math io os coroutine load dofile",
    family="lua", run="lua",
)

LANGS["sql"] = _lang(
    "SQL", [".sql"],
    line_comment="--", block_comment=("/*", "*/"), ci=True, indent=2,
    keywords="select from where insert into values update delete set create"
             " table view index drop alter add primary key foreign references"
             " not null unique default check constraint join inner left right"
             " full outer on as and or in is between like limit offset order by"
             " group having distinct union all exists case when then else end"
             " begin commit rollback transaction if trigger procedure function"
             " returns return declare cascade asc desc",
    types="int integer smallint bigint decimal numeric float real double"
          " precision char varchar text blob boolean date time timestamp"
          " datetime serial uuid json jsonb",
    constants="null true false",
    builtins="count sum avg min max coalesce nullif cast abs round upper lower"
             " length substr trim replace now current_date current_timestamp"
             " random group_concat printf date datetime strftime",
    family="sql", run="sql",
)

LANGS["yaml"] = _lang(
    "YAML", [".yml", ".yaml"],
    line_comment="#", indent=2, ci=True,
    extra=(("keyword", r"^(?:---|\.\.\.)[ \t]*$"),
           ("builtin", r"^[ \t]*(?:- )?[\w.\/-]+(?=[ \t]*:(?:[ \t]|$))"),
           ("decorator", r"[&*][\w-]+|![\w!\/]+")),
    constants="true false null yes no on off",
    family="yaml", run="yaml",
)

LANGS["applescript"] = _lang(
    "AppleScript", [".applescript", ".scpt"],
    line_comment="--", block_comment=("(*", "*)"), ci=True,
    keywords="on end tell to set if then else else if repeat with times"
             " from exit return try error considering ignoring of the my its"
             " it me as property script global local run open activate and or"
             " not is in contains equal greater less than",
    constants="true false missing value pi result current application",
    builtins="display dialog alert say count get first last item items"
             " paragraph paragraphs word words character characters delay beep"
             " choose file log",
    family="applescript", run="applescript",
)

LANGS["perl"] = _lang(
    "Perl", [".pl", ".pm"],
    line_comment="#",
    extra=(("var", r"[\$\@\%]\w+"),),
    keywords="use strict warnings my our local sub if elsif else unless while"
             " until for foreach do last next redo return package require qw"
             " eq ne lt gt le ge cmp and or not xor",
    constants="undef __FILE__ __LINE__ STDIN STDOUT STDERR",
    builtins="print printf say chomp chop push pop shift unshift splice sort"
             " reverse keys values each exists delete defined scalar wantarray"
             " die warn open close split join map grep sprintf length substr"
             " index uc lc ucfirst lcfirst",
    family="ruby", run="perl",
)

LANGS["text"] = _lang("Plain Text", [".txt", ".log", ".cfg", ".ini", ".conf"],
                      line_comment="#", family="text", run="text")

# Preferred order for the "New File" chooser.
LANG_ORDER = ["python", "javascript", "typescript", "html", "css", "json",
              "markdown", "c", "cpp", "java", "csharp", "go", "rust", "swift",
              "kotlin", "ruby", "php", "shell", "lua", "sql", "yaml",
              "applescript", "perl", "text"]

LANG_BY_EXT = {}
for _lid in LANGS:
    for _e in LANGS[_lid]["exts"]:
        LANG_BY_EXT.setdefault(_e, _lid)

SHEBANG_MAP = [("python", "python"), ("node", "javascript"), ("bash", "shell"),
               ("zsh", "shell"), ("sh", "shell"), ("ruby", "ruby"),
               ("perl", "perl"), ("php", "php"), ("osascript", "applescript"),
               ("lua", "lua")]


def detect_language(path=None, first_line=""):
    """Guess the language id from a file path and/or its first line."""
    if path:
        ext = os.path.splitext(path)[1].lower()
        if ext == ".command":
            pass  # decide by shebang below; plain .command is shell
        elif ext in LANG_BY_EXT:
            return LANG_BY_EXT[ext]
    if first_line.startswith("#!"):
        for probe, lid in SHEBANG_MAP:
            if probe in first_line:
                return lid
    if path and os.path.splitext(path)[1].lower() == ".command":
        return "shell"
    if first_line.strip().startswith(("<!DOCTYPE", "<html")):
        return "html"
    if first_line.strip().startswith(("{", "[")):
        return "json"
    return "text"


# --------------------------------------------------------------------------
# New-file skeletons.
# Pure structure, no example code. «label» marks a placeholder the user can
# type over; «» marks where the caret lands. Press Tab to hop between them.
# --------------------------------------------------------------------------

SKELETONS = {
    "python": '#!/usr/bin/env python3\n"""«What this program does.»"""\n\n\n'
              'def main():\n    «»\n\n\nif __name__ == "__main__":\n    main()\n',
    "javascript": '"use strict";\n\nfunction main() {\n  «»\n}\n\nmain();\n',
    "typescript": 'function main(): void {\n  «»\n}\n\nmain();\n',
    "html": '<!DOCTYPE html>\n<html lang="en">\n<head>\n'
            '  <meta charset="UTF-8">\n'
            '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
            '  <title>«Page title»</title>\n</head>\n<body>\n  «»\n</body>\n</html>\n',
    "css": '/* «What this stylesheet is for.» */\n\nbody {\n  «»\n}\n',
    "json": '{\n  «»\n}\n',
    "markdown": '# «Title»\n\n«»\n',
    "c": '#include <stdio.h>\n#include <stdlib.h>\n\n'
         'int main(int argc, char *argv[]) {\n    «»\n    return 0;\n}\n',
    "cpp": '#include <iostream>\n#include <string>\n#include <vector>\n\n'
           'int main(int argc, char *argv[]) {\n    «»\n    return 0;\n}\n',
    "csharp": 'using System;\n\nclass Program {\n'
              '    static void Main(string[] args) {\n        «»\n    }\n}\n',
    "java": 'public class Main {\n'
            '    public static void main(String[] args) {\n        «»\n    }\n}\n',
    "go": 'package main\n\nfunc main() {\n\t«»\n}\n',
    "rust": 'fn main() {\n    «»\n}\n',
    "swift": 'import Foundation\n\n«»\n',
    "kotlin": 'fun main() {\n    «»\n}\n',
    "ruby": '#!/usr/bin/env ruby\n# frozen_string_literal: true\n\n'
            'def main\n  «»\nend\n\nmain if __FILE__ == $PROGRAM_NAME\n',
    "php": '<?php\n\n«»\n',
    "shell": '#!/usr/bin/env bash\nset -euo pipefail\n\n'
             'main() {\n  «»\n}\n\nmain "$@"\n',
    "lua": 'local function main()\n  «»\nend\n\nmain()\n',
    "sql": '-- «What this query does.»\n\n«»\n',
    "yaml": '# «What this file configures.»\n\n«»\n',
    "applescript": 'on run\n\t«»\nend run\n',
    "perl": '#!/usr/bin/env perl\nuse strict;\nuse warnings;\n\n«»\n',
    "text": '«»\n',
}

# --------------------------------------------------------------------------
# Tab-expandable snippets ("type the keyword, press Tab").
# "\t" means one indent unit; "\n" lines are re-indented to the caret's level.
# --------------------------------------------------------------------------

SNIPPETS = {
    "python": {
        "if": "if «condition»:\n\t«»",
        "elif": "elif «condition»:\n\t«»",
        "else": "else:\n\t«»",
        "for": "for «item» in «iterable»:\n\t«»",
        "while": "while «condition»:\n\t«»",
        "def": "def «name»(«args»):\n\t«»",
        "class": "class «Name»:\n\tdef __init__(self):\n\t\t«»",
        "try": "try:\n\t«»\nexcept «Exception» as exc:\n\traise",
        "with": "with «expression» as «name»:\n\t«»",
        "main": 'def main():\n\t«»\n\nif __name__ == "__main__":\n\tmain()',
    },
    "clike": {
        "if": "if («condition») {\n\t«»\n}",
        "else": "else {\n\t«»\n}",
        "for": "for (int i = 0; i < «n»; i++) {\n\t«»\n}",
        "while": "while («condition») {\n\t«»\n}",
        "switch": "switch («value») {\ncase «a»:\n\t«»\n\tbreak;\ndefault:\n\tbreak;\n}",
        "function": "function «name»(«args») {\n\t«»\n}",
        "func": "func «name»(«args») {\n\t«»\n}",
        "try": "try {\n\t«»\n} catch («err») {\n\t«»\n}",
        "do": "do {\n\t«»\n} while («condition»);",
    },
    "shell": {
        "if": "if [ «condition» ]; then\n\t«»\nfi",
        "for": "for «x» in «list»; do\n\t«»\ndone",
        "while": "while «condition»; do\n\t«»\ndone",
        "case": "case «$var» in\n«pattern»)\n\t«»\n\t;;\nesac",
        "func": "«name»() {\n\t«»\n}",
    },
    "ruby": {
        "if": "if «condition»\n\t«»\nend",
        "def": "def «name»\n\t«»\nend",
        "each": "«list».each do |«item»|\n\t«»\nend",
        "class": "class «Name»\n\t«»\nend",
        "while": "while «condition»\n\t«»\nend",
    },
    "lua": {
        "if": "if «condition» then\n\t«»\nend",
        "for": "for i = 1, «n» do\n\t«»\nend",
        "while": "while «condition» do\n\t«»\nend",
        "function": "local function «name»(«args»)\n\t«»\nend",
    },
    "sql": {
        "select": "select «columns»\nfrom «table»\nwhere «condition»;",
    },
    "applescript": {
        "if": "if «condition» then\n\t«»\nend if",
        "repeat": "repeat «n» times\n\t«»\nend repeat",
        "tell": 'tell application "«App»"\n\t«»\nend tell',
    },
}

PLACEHOLDER_RE = re.compile(r"«([^«»\n]*)»")


def parse_placeholders(s):
    """Strip «...» markers. Return (clean_text, [(start, end), ...])."""
    spans = []
    clean = []
    pos = 0
    removed = 0
    for m in PLACEHOLDER_RE.finditer(s):
        clean.append(s[pos:m.start()])
        start = m.start() - removed
        label = m.group(1)
        clean.append(label)
        spans.append((start, start + len(label)))
        removed += 2
        pos = m.end()
    clean.append(s[pos:])
    return "".join(clean), spans


def indent_unit(sp):
    return "\t" if sp["indent_char"] == "\t" else " " * sp["indent"]


# --------------------------------------------------------------------------
# Tokenizer: one master regex per language, then word classification.
# --------------------------------------------------------------------------

_LEXERS = {}


def get_lexer(lang_id):
    got = _LEXERS.get(lang_id)
    if got:
        return got
    sp = LANGS[lang_id]
    alts = []
    ttmap = {}

    def add(tt, pat):
        name = "g%d" % len(ttmap)
        ttmap[name] = tt
        alts.append("(?P<%s>%s)" % (name, pat))

    for tt, pat in sp["extra"]:
        add(tt, pat)
    if sp["block_comment"]:
        o, c = sp["block_comment"]
        add("comment", re.escape(o) + r"(?s:.*?)(?:" + re.escape(c) + r"|\Z)")
    if sp["line_comment"]:
        add("comment", re.escape(sp["line_comment"]) + r"[^\n]*")
    pref = r"[rRbBuUfF]{0,2}" if sp["str_prefix"] else ""
    if sp["triple"]:
        add("string",
            pref + r"(?:'''(?s:.*?)(?:'''|\Z)|\"\"\"(?s:.*?)(?:\"\"\"|\Z))")
    if sp["backtick"]:
        add("string", r"`(?s:(?:\\.|[^`\\])*)(?:`|\Z)")
    for q in sp["strings"]:
        add("string",
            pref + q + r"(?:\\.|[^\\" + q + r"\n])*(?:" + q + r"|$)")
    if sp["preproc"]:
        add("preproc", sp["preproc"])
    if sp["decorator"]:
        add("decorator", sp["decorator"])
    add("number",
        r"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+"
        r"|(?:\d[\d_]*(?:\.\d[\d_]*)?|\.\d[\d_]+)(?:[eE][+-]?\d+)?)[jJfFlLuUnm]*")
    add("word", r"[A-Za-z_][A-Za-z0-9_]*")
    add("brk", r"[\[\](){}]")
    add("op", r"[-+*/%=<>!&|^~?@\\]+")
    add("punct", r"[.,:;]+")
    rx = re.compile("|".join(alts), re.M)
    got = (rx, ttmap, sp)
    _LEXERS[lang_id] = got
    return got


def tokenize(text, lang_id):
    """Return [(start, end, token_type), ...] for the whole text."""
    rx, ttmap, sp = get_lexer(lang_id)
    kw = sp["keywords"]
    types = sp["types"]
    consts = sp["constants"]
    bins = sp["builtins"]
    ci = sp["ci"]
    out = []
    n = len(text)
    for m in rx.finditer(text):
        tt = ttmap[m.lastgroup]
        s, e = m.span()
        if s == e:
            continue
        if tt == "word":
            w = m.group()
            lw = w.lower() if ci else w
            if lw in kw:
                tt = "keyword"
            elif lw in types:
                tt = "type"
            elif lw in consts:
                tt = "const"
            elif lw in bins:
                tt = "builtin"
            else:
                j = e
                while j < n and text[j] in " \t":
                    j += 1
                if j < n and text[j] == "(":
                    tt = "func"
                elif len(w) > 1 and w.isupper():
                    tt = "const"
                elif w[:1].isupper():
                    tt = "cls"
                else:
                    tt = "ident"
        out.append((s, e, tt))
    return out


class LineIndex:
    """Maps absolute character offsets to (line, col) / Tk 'line.col' indexes."""

    def __init__(self, text):
        starts = [0]
        pos = text.find("\n")
        while pos != -1:
            starts.append(pos + 1)
            pos = text.find("\n", pos + 1)
        self.starts = starts

    def line_col(self, off):
        ln = bisect_right(self.starts, off)
        return ln, off - self.starts[ln - 1]

    def tk(self, off):
        ln, col = self.line_col(off)
        return "%d.%d" % (ln, col)


BRK_PAIR = {"(": ")", "[": "]", "{": "}"}
BRK_MATCH = {")": "(", "]": "[", "}": "{"}


def scan_brackets(text, tokens):
    """Walk bracket tokens (strings/comments excluded because they arrive as
    single tokens). Returns:
      retype:   {token_index: "brk0|1|2"}  rainbow depth colors
      unclosed: [(offset, char)] opens never closed (in stack order)
      stray:    [(offset, char)] closes with nothing to close
      events:   [(offset, +1|-1)] depth change events, in order
    """
    retype = {}
    unclosed = []
    stray = []
    events = []
    stack = []
    for i, tok in enumerate(tokens):
        s, e, tt = tok
        if tt != "brk":
            continue
        ch = text[s:e]
        if ch in BRK_PAIR:
            retype[i] = "brk%d" % (len(stack) % 3)
            stack.append((s, ch))
            events.append((s, 1))
        else:
            if stack and stack[-1][1] == BRK_MATCH[ch]:
                stack.pop()
                retype[i] = "brk%d" % (len(stack) % 3)
                events.append((s, -1))
            elif stack:
                stray.append((s, ch))
                stack.pop()
                retype[i] = "brk%d" % (len(stack) % 3)
                events.append((s, -1))
            else:
                retype[i] = "brk0"
                stray.append((s, ch))
    unclosed.extend(stack)
    return retype, unclosed, stray, events


def depth_at_line_starts(line_starts, events):
    """Bracket nesting depth at the start of every line (0-indexed list)."""
    depths = []
    d = 0
    j = 0
    for ls in line_starts:
        while j < len(events) and events[j][0] < ls:
            d += events[j][1]
            j += 1
        depths.append(d)
    return depths


# --------------------------------------------------------------------------
# Auto-check: find problems, describe them kindly, and know how to fix them.
# --------------------------------------------------------------------------

Issue = namedtuple("Issue", "line col end severity msg fix")
# line: 1-based, col/end: 0-based columns, severity: error|warn|info,
# fix: (kind, data) or None.
OutlineItem = namedtuple("OutlineItem", "line level kind name")

SEV_ORDER = {"error": 0, "warn": 1, "info": 2}

COMPOUND_PY = {"if", "elif", "else", "for", "while", "def", "class", "try",
               "except", "finally", "with"}
CLIKE_SEMI_LANGS = {"c", "cpp", "java", "csharp"}
SEMI_SKIP_START = {"if", "else", "for", "while", "switch", "do", "case",
                   "default", "try", "catch", "finally", "template",
                   "namespace", "using", "public", "private", "protected"}
NO_BRACKET_CHECK = {"markdown", "text", "html"}

# --------------------------------------------------------------------------
# HTML structure analysis: tag balance, dangling '<', mismatched closes.
# --------------------------------------------------------------------------

HTML_VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
             "link", "meta", "param", "source", "track", "wbr"}
# Tags that HTML5 closes implicitly (a bare <li> or <p> is valid markup).
HTML_IMPLIED = {"li", "p", "td", "th", "tr", "option", "dd", "dt", "thead",
                "tbody", "tfoot", "colgroup", "caption", "optgroup", "html",
                "head", "body"}
HTML_RAW = {"script", "style", "pre", "textarea"}

_HTML_TAG_RE = re.compile(
    r"<(/?)([a-zA-Z][a-zA-Z0-9-]*)((?:[^<>\"']|\"[^\"]*\"|'[^']*')*)(/?)>")
_HTML_SKIP_RE = re.compile(
    r"<!--.*?(?:-->|\Z)|<!\[CDATA\[.*?(?:\]\]>|\Z)|<![^>]*>|<\?[^>]*\?>",
    re.S)


def html_scan(text):
    """Walk the markup. Returns (problems, open_stack, raw_spans) where
    problems are dicts: kind in unclosed|mismatch|stray, plus positions."""
    skip = []
    for m in _HTML_SKIP_RE.finditer(text):
        skip.append((m.start(), m.end()))

    def skipped(pos):
        return any(a <= pos < b for a, b in skip)

    problems = []
    stack = []          # [(name, pos)]
    covered = []        # spans of recognized tags
    raw_until = None
    raw_name = None
    for m in _HTML_TAG_RE.finditer(text):
        if skipped(m.start()):
            continue
        closing, name, attrs, selfclose = m.groups()
        lname = name.lower()
        if raw_until is not None:
            if closing and lname == raw_name:
                raw_until = None
                raw_name = None
                covered.append((m.start(), m.end()))
                if stack and stack[-1][0] == lname:
                    stack.pop()
            continue
        covered.append((m.start(), m.end()))
        if not closing:
            if lname in HTML_VOID or selfclose:
                continue
            stack.append((lname, m.start()))
            if lname in HTML_RAW:
                raw_until = True
                raw_name = lname
            continue
        # closing tag
        names = [n for n, _ in stack]
        if lname not in names:
            problems.append({"kind": "mismatch", "pos": m.start(),
                             "end": m.end(), "close": lname,
                             "open": stack[-1][0] if stack else None})
            continue
        while stack and stack[-1][0] != lname:
            popped, ppos = stack.pop()
            if popped not in HTML_IMPLIED:
                # this close tag force-closed an inner element; the repair
                # belongs right HERE, before the forcing close tag
                problems.append({"kind": "unclosed", "pos": ppos,
                                 "name": popped, "force_pos": m.start(),
                                 "force_close": lname})
        if stack:
            stack.pop()
    # dangling '<' that never formed a tag
    for i, ch in enumerate(text):
        if ch != "<" or skipped(i):
            continue
        if any(a <= i < b for a, b in covered):
            continue
        problems.append({"kind": "stray", "pos": i})
    for name, pos in stack:
        if name not in HTML_IMPLIED:
            problems.append({"kind": "unclosed", "pos": pos, "name": name})
    return problems, stack, skip


def html_check(text, li=None):
    """Issues for the live checker (with fixes GeckoFix knows how to apply)."""
    issues = []
    try:
        problems, stack, _ = html_scan(text)
    except Exception:
        return issues
    li = li or LineIndex(text)
    lines = text.split("\n")
    # Force-closed elements: repairs at the same spot must be emitted in
    # REVERSE pop order so bottom-up application nests them correctly.
    forced = [p for p in problems if p["kind"] == "unclosed"
              and p.get("force_pos") is not None]
    by_force = {}
    for p in forced:
        by_force.setdefault(p["force_pos"], []).append(p)
    ordered = []
    for p in problems:
        if p["kind"] == "unclosed" and p.get("force_pos") is not None:
            group = by_force.pop(p["force_pos"], None)
            if group:
                ordered.extend(reversed(group))
        else:
            ordered.append(p)
    completed_by_stray = set()
    for p in ordered[:30]:
        ln, col = li.line_col(p["pos"])
        line_text = lines[ln - 1] if ln - 1 < len(lines) else ""
        if p["kind"] == "stray":
            rest = line_text[col:]
            # What is open right HERE? Scan the prefix.
            inner = None
            try:
                _, pstack, _ = html_scan(text[:p["pos"]])
                if pstack:
                    inner = pstack[-1][0]
            except Exception:
                pass
            frag = rest.rstrip()
            want = "</%s>" % inner if inner else ""
            partial = re.match(r"^</?[a-zA-Z0-9-]*$", frag or "<")
            if want and partial and (frag in ("<", "</")
                                     or want.startswith(frag)):
                completed_by_stray.add(inner)
                issues.append(Issue(
                    ln, col, col + len(frag), "error",
                    "Incomplete tag - finish it as '%s'" % want,
                    ("span", (col, col + len(frag), want))))
            else:
                issues.append(Issue(ln, col, col + 1, "error",
                                    "Stray '<' - write &lt; for a literal "
                                    "less-than", ("span", (col, col + 1,
                                                           "&lt;"))))
        elif p["kind"] == "unclosed":
            want = "</%s>" % p["name"]
            if p["name"] in completed_by_stray:
                # the completed dangling tag will close this element
                completed_by_stray.discard(p["name"])
                continue
            if p.get("force_pos") is not None:
                fl, fc = li.line_col(p["force_pos"])
                issues.append(Issue(
                    fl, fc, fc + 1, "warn",
                    "<%s> (line %d) is still open here - add %s"
                    % (p["name"], ln, want),
                    ("span", (fc, fc, want))))
            else:
                issues.append(Issue(ln, col, col + len(p["name"]) + 1, "warn",
                                    "<%s> is never closed - add %s"
                                    % (p["name"], want),
                                    ("append_eof", want)))
        elif p["kind"] == "mismatch":
            end_col = li.line_col(p["end"])[1]
            if p["open"]:
                want = "</%s>" % p["open"]
                issues.append(Issue(ln, col, end_col, "error",
                                    "</%s> closes nothing that is open - "
                                    "did you mean %s?" % (p["close"], want),
                                    ("span", (col, end_col, want))))
            else:
                issues.append(Issue(ln, col, end_col, "error",
                                    "</%s> closes nothing that is open - "
                                    "removing it" % p["close"],
                                    ("span", (col, end_col, ""))))
    return issues


def split_code_comment(line, lc):
    """Split a single line into (code, comment) respecting quotes."""
    if not lc:
        return line, ""
    q = None
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif line.startswith(lc, i):
            return line[:i], line[i:]
        i += 1
    return line, ""


def _masked(text, li, ln, ltoks, line_text):
    """Line text with string/comment tokens blanked out."""
    start = li.starts[ln - 1]
    buf = list(line_text)
    for s, e, tt in ltoks:
        if tt in ("string", "comment", "codeblock"):
            for k in range(max(s, start), min(e, start + len(buf))):
                buf[k - start] = " "
    return "".join(buf)


def check_source(text, lang_id, filename=None, max_issues=40, heuristics=True):
    """Analyze source, return a list of Issue tuples (sorted, capped).

    heuristics=False skips the guess-based checks (missing ';', '=' in a
    condition) - used when a real compiler is available to lint this language,
    since the compiler reports those precisely and the guesses only add noise.
    """
    sp = LANGS[lang_id]
    issues = []
    error_lines = set()

    def add(line, col, end, sev, msg, fix=None):
        issues.append(Issue(line, col, max(end, col), sev, msg, fix))
        if sev == "error":
            error_lines.add(line)

    tokens = tokenize(text, lang_id)
    li = LineIndex(text)
    lines = text.split("\n")
    retype, unclosed, stray, events = scan_brackets(text, tokens)
    depths = depth_at_line_starts(li.starts, events)
    # Depth counting only () and [] - a curly brace opens a block, not a
    # statement continuation, so it must not gate the semicolon check.
    paren_events = [(s, 1 if text[s:e] in "([" else -1)
                    for s, e, tt in tokens
                    if tt == "brk" and text[s:e] in "()[]"]
    paren_depths = depth_at_line_starts(li.starts, paren_events)

    # Multi-line string/comment spans (skip line-level checks inside them).
    ml_spans = []
    by_line = {}
    for s, e, tt in tokens:
        ln = li.line_col(s)[0]
        by_line.setdefault(ln, []).append((s, e, tt))
        if tt in ("string", "comment", "codeblock") and "\n" in text[s:e]:
            ml_spans.append((ln, li.line_col(e - 1)[0]))

    def in_multiline(ln):
        return any(a < ln <= b for a, b in ml_spans)

    # ---- unterminated strings ------------------------------------------
    for s, e, tt in tokens:
        if tt != "string":
            continue
        tok = text[s:e]
        m = re.search(r"['\"`]", tok[:4])
        if not m:
            continue
        q = m.group(0)
        qpos = m.start()
        if tok[qpos:qpos + 3] == q * 3 and sp["triple"]:
            if not (len(tok) >= qpos + 6 and tok.endswith(q * 3)):
                ln, col = li.line_col(s)
                add(ln, col, col + 3, "warn",
                    "This triple-quoted string is never closed",
                    ("append_eof", q * 3))
            continue
        if "\n" in tok:  # unterminated backtick template reaching EOF
            if not (len(tok) >= qpos + 2 and tok.endswith(q)):
                ln, col = li.line_col(s)
                add(ln, col, col + 1, "warn",
                    "This template string is never closed", ("append_eof", q))
            continue
        if not (len(tok) >= qpos + 2 and tok.endswith(q)):
            ln, col = li.line_col(s)
            add(ln, col, len(lines[ln - 1]), "error",
                "Unclosed string - add a closing %s" % q, ("close_string", q))

    # ---- unbalanced brackets (whole document) --------------------------
    if lang_id not in NO_BRACKET_CHECK:
        brace_block = (sp["family"] == "clike"
                       or lang_id in ("go", "rust", "swift", "kotlin",
                                      "css", "json", "perl"))
        for off, ch in unclosed:
            ln, col = li.line_col(off)
            # An unclosed '{' opens a BLOCK: the right repair is a closing
            # brace at the end of the file, not on the opening line.
            if ch == "{" and brace_block:
                fix = ("append_eof", "\n}")
            else:
                fix = ("close_line", BRK_PAIR[ch])
            add(ln, col, col + 1, "warn",
                "'%s' is never closed - add '%s'" % (ch, BRK_PAIR[ch]), fix)
        for off, ch in stray:
            ln, col = li.line_col(off)
            add(ln, col, col + 1, "error",
                "Unexpected '%s' - nothing here needs closing" % ch)

    # ---- per-line checks ------------------------------------------------
    lc = sp["line_comment"]
    for ln in sorted(by_line):
        if in_multiline(ln) or len(issues) >= max_issues:
            continue
        ltoks = by_line[ln]
        line_text = lines[ln - 1] if ln - 1 < len(lines) else ""
        masked = _masked(text, li, ln, ltoks, line_text)

        # Python: compound statement missing ':'
        if lang_id == "python" and depths[ln - 1] == 0:
            code_toks = [t for t in ltoks if t[2] != "comment"]
            if code_toks:
                w0 = text[code_toks[0][0]:code_toks[0][1]]
                head = w0
                if w0 == "async" and len(code_toks) > 1:
                    head = text[code_toks[1][0]:code_toks[1][1]]
                if (code_toks[0][2] == "keyword" and
                        (w0 in COMPOUND_PY or
                         (w0 == "async" and head in ("def", "for", "with")))):
                    d = 0
                    has_colon = False
                    for s, e, tt in code_toks:
                        chs = text[s:e]
                        if tt == "brk":
                            d += 1 if chs in BRK_PAIR else -1
                        elif tt == "punct" and d == 0 and ":" in chs:
                            has_colon = True
                    lastc = text[code_toks[-1][0]:code_toks[-1][1]]
                    if d == 0 and not has_colon and not lastc.endswith("\\"):
                        c0 = li.line_col(code_toks[0][0])[1]
                        c1 = li.line_col(code_toks[-1][1] - 1)[1] + 1
                        add(ln, c0, c1, "error",
                            "Missing ':' at the end of this '%s' statement"
                            % head, ("colon", None))

        # Python 2 style print. Match on the raw line (not the string-masked
        # one) so that `print "hello"` - whose argument is blanked out in the
        # masked copy - is still caught.
        if lang_id == "python" and depths[ln - 1] == 0:
            m = re.match(r"^[ \t]*print[ \t]+[^(=\s]", line_text)
            if m:
                col = len(line_text) - len(line_text.lstrip())
                add(ln, col, col + 5, "warn",
                    "In Python 3, print needs parentheses: print(...)",
                    ("print_call", None))

        # Python: tabs mixed with spaces in indentation
        if lang_id == "python" and re.match(r"^(?: +\t|\t+ )", line_text):
            add(ln, 0, len(line_text) - len(line_text.lstrip()), "warn",
                "Indentation mixes tabs and spaces", ("untabify", None))

        # '=' inside an if/while condition (C-family)
        if heuristics and (sp["family"] == "clike" or
                           lang_id in CLIKE_SEMI_LANGS):
            m = re.search(r"\b(if|while)\b[ \t]*\(([^()]*)", masked)
            if m:
                m2 = re.search(r"(?<![=!<>+\-*/%&|^])=(?![=>])", m.group(2))
                if m2:
                    col = m.start(2) + m2.start()
                    add(ln, col, col + 1, "warn",
                        "'=' assigns a value - did you mean '=='?",
                        ("eq_cond", None))

        # Possible missing semicolon (conservative, info only).
        # Gate on paren/bracket depth so statements inside a { } block are
        # checked, but continuation lines inside ( ) or [ ] are not.
        if (heuristics and lang_id in CLIKE_SEMI_LANGS
                and paren_depths[ln - 1] == 0):
            t = masked.rstrip()
            st = t.lstrip()
            net = 0
            for s, e, tt in ltoks:
                if tt == "brk":
                    net += 1 if text[s:e] in BRK_PAIR else -1
            if t and net == 0 and st and not st.startswith(("#", "@", "/", "}", "*")):
                last = t[-1]
                ok_end = (last.isalnum() or last in "_)]\"'" or
                          t.endswith("++") or t.endswith("--"))
                w = re.match(r"[A-Za-z_]*", st).group(0)
                nxt = ""
                for k in range(ln, min(ln + 3, len(lines))):
                    if lines[k].strip():
                        nxt = lines[k].strip()
                        break
                if (ok_end and w not in SEMI_SKIP_START and
                        not (nxt and nxt[0] in "{.)+-*/=<>?&|,:;")):
                    add(ln, len(t) - 1, len(t), "info",
                        "This statement may be missing a ';'",
                        ("semicolon", None))

    # ---- whole-file syntax checks ---------------------------------------
    if lang_id == "python" and len(text) < 300000:
        try:
            tree = ast.parse(text, filename or "<geskoide>")
        except SyntaxError as ex:
            ln = ex.lineno or 1
            if ln not in error_lines:
                col = max(0, (ex.offset or 1) - 1)
                add(ln, col, col + 1, "error",
                    "Python: %s" % (ex.msg or "invalid syntax"))
        except Exception:
            pass
        else:
            # Real semantic analysis: undefined names, unused imports.
            try:
                for l, c, sev, msg, fix in analyze_python(tree):
                    if l not in error_lines:
                        add(l, c, c + 1, sev, msg, fix)
            except Exception:
                pass

    if lang_id == "json" and text.strip() and "//" not in text:
        try:
            json.loads(text)
        except json.JSONDecodeError as ex:
            if ex.lineno not in error_lines:
                add(ex.lineno, max(0, ex.colno - 1), ex.colno, "error",
                    "JSON: %s" % ex.msg)
        except Exception:
            pass

    if lang_id == "html" and len(text) < 300000:
        for iss in html_check(text, li):
            if len(issues) < max_issues:
                issues.append(iss)
                if iss.severity == "error":
                    error_lines.add(iss.line)

    if lang_id == "java" and filename:
        stem = os.path.splitext(os.path.basename(filename))[0]
        m = re.search(r"\bpublic\s+(?:final\s+|abstract\s+)*"
                      r"(?:class|interface|enum|record)\s+(\w+)", text)
        if m and re.match(r"^\w+$", stem) and m.group(1) != stem:
            ln = text[:m.start(1)].count("\n") + 1
            col = m.start(1) - (text.rfind("\n", 0, m.start(1)) + 1)
            add(ln, col, col + len(m.group(1)), "warn",
                "Public class '%s' should match the file name '%s'"
                % (m.group(1), stem), ("rename_class", stem))

    issues.sort(key=lambda i: (i.line, SEV_ORDER[i.severity], i.col))
    return issues[:max_issues]


# --------------------------------------------------------------------------
# Python semantic analysis (offline, standard-library `ast`).
# Conservative on purpose: only flags a name that is used but never bound
# ANYWHERE in the module, so real typos surface without false alarms.
# --------------------------------------------------------------------------

_PY_BUILTINS = set(dir(_builtins)) | {
    "__file__", "__name__", "__doc__", "__spec__", "__loader__",
    "__package__", "__builtins__", "__debug__", "__dict__", "__class__",
    "__module__", "__qualname__", "__annotations__", "self", "cls", "_"}

_MatchAs = getattr(ast, "MatchAs", None)
_MatchStar = getattr(ast, "MatchStar", None)
_MatchMapping = getattr(ast, "MatchMapping", None)


def analyze_python(tree):
    """Return [(line, col, severity, message, fix), ...]."""
    defined = set()
    used = {}
    imported = {}
    star = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                nm = a.asname or a.name.split(".")[0]
                defined.add(nm)
                imported[nm] = (node.lineno, a.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module == "__future__":
                continue
            for a in node.names:
                if a.name == "*":
                    star = True
                    continue
                nm = a.asname or a.name
                defined.add(nm)
                imported[nm] = (node.lineno, a.name)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef,
                               ast.ClassDef)):
            defined.add(node.name)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            defined.add(node.name)
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            defined.update(node.names)
        elif isinstance(node, ast.arg):
            defined.add(node.arg)
        elif isinstance(node, ast.Name):
            if isinstance(node.ctx, (ast.Store, ast.Del)):
                defined.add(node.id)
            else:
                used.setdefault(node.id, (node.lineno, node.col_offset))
        elif _MatchAs and isinstance(node, _MatchAs) and node.name:
            defined.add(node.name)
        elif _MatchStar and isinstance(node, _MatchStar) and node.name:
            defined.add(node.name)
        elif _MatchMapping and isinstance(node, _MatchMapping) and node.rest:
            defined.add(node.rest)

    out = []
    has_all = "__all__" in defined
    if not star:
        for name, (l, c) in used.items():
            if name not in defined and name not in _PY_BUILTINS:
                out.append((l, c, "warn",
                            "'%s' is not defined - a typo or a missing import?"
                            % name, None))
    used_ids = set(used)
    if not star and not has_all:
        for nm, (l, full) in imported.items():
            if not nm.startswith("_") and nm not in used_ids:
                out.append((l, 0, "info",
                            "'%s' is imported but never used" % nm, None))
    return out


# --------------------------------------------------------------------------
# External diagnostics: run the language's OWN compiler/checker (already on
# this computer) to get real, precise errors - fully offline, no APIs.
# --------------------------------------------------------------------------

def _java_stem(text):
    m = re.search(r"\bpublic\s+(?:final\s+|abstract\s+|sealed\s+)*"
                  r"(?:class|interface|enum|record)\s+(\w+)", text)
    return (m.group(1) if m else "Main") + ".java"


# lang_id -> dict(tools, args(tool, path)->argv, parse, name(text)->filename)
EXTERNAL_LINTERS = {
    "c": dict(tools=("clang", "gcc", "cc"),
              args=lambda t, p: [t, "-fsyntax-only", "-fno-caret-diagnostics",
                                 "-Wall", p], parse="gcc"),
    "cpp": dict(tools=("clang++", "g++", "c++"),
                args=lambda t, p: [t, "-fsyntax-only",
                                   "-fno-caret-diagnostics", "-std=c++17",
                                   "-Wall", p], parse="gcc"),
    "javascript": dict(tools=("node",),
                       args=lambda t, p: [t, "--check", p], parse="node"),
    "typescript": dict(tools=("tsc", "deno"),
                       args=lambda t, p: ([t, "--noEmit", "--pretty", "false",
                                           "--target", "es2020", "--module",
                                           "esnext", p] if t.endswith("tsc")
                                          else [t, "check", p]), parse="tsc"),
    "shell": dict(tools=("bash",), args=lambda t, p: [t, "-n", p],
                  parse="bash"),
    "php": dict(tools=("php",), args=lambda t, p: [t, "-l", p], parse="php"),
    "ruby": dict(tools=("ruby",), args=lambda t, p: [t, "-c", p],
                 parse="ruby"),
    "perl": dict(tools=("perl",), args=lambda t, p: [t, "-c", p],
                 parse="perl"),
    "lua": dict(tools=("luac", "luac5.4", "luac5.3"),
                args=lambda t, p: [t, "-p", p], parse="gcc"),
    "go": dict(tools=("gofmt",), args=lambda t, p: [t, "-e", p], parse="gcc"),
    "java": dict(tools=("javac",),
                 args=lambda t, p: [t, "-d", os.path.dirname(p),
                                    "-Xlint:none", p], parse="gcc",
                 name=_java_stem),
}

_tool_cache = {}
_tool_health = {}


def _tool_healthy(tool):
    """True when the tool actually runs. On a Mac WITHOUT the Command Line
    Tools, /usr/bin/clang & co. exist as Apple shims that only print an
    'install developer tools' notice - treating those as real compilers made
    diagnostics and fixes silently disappear."""
    if tool in _tool_health:
        return _tool_health[tool]
    ok = True
    try:
        r = subprocess.run([tool, "--version"], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=6)
        out = (r.stdout or b"").lower()
        if (b"xcode-select" in out or b"developer tools" in out
                or b"command line tools" in out):
            ok = False
    except Exception:
        ok = False
    _tool_health[tool] = ok
    return ok


def linter_tool(lang_id):
    """Path of a WORKING checker for a language, or None. Cached."""
    spec = EXTERNAL_LINTERS.get(lang_id)
    if not spec:
        return None
    if lang_id not in _tool_cache:
        tool = which_tool(*spec["tools"])
        if tool and not _tool_healthy(tool):
            tool = None
        _tool_cache[lang_id] = tool
    return _tool_cache[lang_id]


_DIAG_FULL = re.compile(
    r"^(?P<f>.*?):(?P<l>\d+):(?P<c>\d+):\s*"
    r"(?P<s>fatal error|error|warning|note):\s*(?P<m>.*)$")
_DIAG_LINE = re.compile(
    r"^(?P<f>.*?):(?P<l>\d+):\s*(?P<s>error|warning):\s*(?P<m>.*)$")


def _sev_of(word):
    if "error" in word:
        return "error"
    if "warn" in word:
        return "warn"
    return "info"


def _fix_for(msg):
    m = msg.lower()
    if ("expected ';'" in m or "';' expected" in m or "missing ';'" in m
            or "expected ';' after" in m):
        return ("semicolon", None)
    return None


def parse_diagnostics(kind, out):
    """Parse a checker's output into [(line, col, sev, msg, fix), ...]."""
    res = []
    node_line = None
    for raw in out.splitlines():
        line = raw.rstrip()
        if kind == "gcc":
            m = _DIAG_FULL.match(line)
            if m and m.group("s") != "note":
                res.append((int(m.group("l")), max(0, int(m.group("c")) - 1),
                            _sev_of(m.group("s")), m.group("m").strip(),
                            _fix_for(m.group("m"))))
                continue
            m = _DIAG_LINE.match(line)
            if m:
                res.append((int(m.group("l")), 0, _sev_of(m.group("s")),
                            m.group("m").strip(), _fix_for(m.group("m"))))
        elif kind == "node":
            m = re.match(r"^.*?:(\d+)$", line.strip())
            if m and node_line is None:
                node_line = int(m.group(1))
            m = re.match(r"^([A-Za-z]+Error): (.*)$", line.strip())
            if m:
                res.append((node_line or 1, 0, "error",
                            "%s: %s" % (m.group(1), m.group(2)), None))
        elif kind == "bash":
            m = re.search(r"line (\d+): (.*)$", line)
            if m:
                res.append((int(m.group(1)), 0, "error",
                            m.group(2).strip(), None))
        elif kind == "php":
            m = re.search(r"(?:Parse|Fatal|syntax) error:\s*(.*?) in .* "
                          r"on line (\d+)", line)
            if m:
                res.append((int(m.group(2)), 0, "error",
                            m.group(1).strip(), None))
        elif kind == "ruby":
            m = re.match(r"^(?:ruby: )?.+?:(\d+): (?:(warning): )?(.*)$", line)
            if m:
                msg = re.sub(r"\s*\((?:Syntax)?Error\)\s*$", "", m.group(3))
                res.append((int(m.group(1)), 0,
                            "warn" if m.group(2) else "error",
                            msg.strip(), None))
        elif kind == "perl":
            if "syntax OK" in line:
                continue
            m = re.search(r"^(.*?) at .*? line (\d+)", line)
            if m:
                res.append((int(m.group(2)), 0, "error",
                            m.group(1).strip(), None))
        elif kind == "tsc":
            m = re.match(r"^(.*?)[\(:](\d+),(\d+)[\):]:?\s*"
                         r"(error|warning) TS\d+:\s*(.*)$", line)
            if m:
                res.append((int(m.group(2)), max(0, int(m.group(3)) - 1),
                            _sev_of(m.group(4)), m.group(5).strip(), None))
    return res


def run_linter(lang_id, text):
    """Run the external checker and return raw diagnostics (or [])."""
    spec = EXTERNAL_LINTERS.get(lang_id)
    tool = linter_tool(lang_id)
    if not spec or not tool:
        return []
    d = tempfile.mkdtemp(prefix="geskolint-")
    try:
        name = spec.get("name", lambda _t: "buffer" + LANGS[lang_id]["exts"][0])
        fname = name(text) if callable(name) else name
        path = os.path.join(d, fname)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text if text.endswith("\n") else text + "\n")
        argv = spec["args"](tool, path)
        env = dict(os.environ)
        env["LC_ALL"] = env.get("LC_ALL", "C")
        try:
            proc = subprocess.run(argv, cwd=d, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True,
                                  timeout=9, env=env, errors="replace")
        except (subprocess.TimeoutExpired, OSError):
            return []
        return parse_diagnostics(spec["parse"], proc.stdout or "")
    except Exception as ex:
        _log_error("run_linter", ex)
        return []
    finally:
        shutil.rmtree(d, ignore_errors=True)


def fixed_line_text(line, issue, sp):
    """Return the repaired version of one line, or None if not applicable."""
    kind, data = issue.fix
    lc = sp["line_comment"]
    code, comment = split_code_comment(line, lc)
    tail = ("  " + comment) if comment else ""
    if kind == "colon":
        base = code.rstrip()
        if not base or base.endswith(":"):
            return None
        return base + ":" + tail
    if kind == "close_line":
        return code.rstrip() + data + tail
    if kind == "close_string":
        return line + data
    if kind == "semicolon":
        base = code.rstrip()
        if not base or base.endswith(";"):
            return None
        return base + ";" + tail
    if kind == "print_call":
        m = re.match(r"^([ \t]*)print[ \t]+(.+?)[ \t]*$", code)
        if not m:
            return None
        return m.group(1) + "print(" + m.group(2) + ")" + tail
    if kind == "untabify":
        m = re.match(r"^[ \t]+", line)
        if not m:
            return None
        ws = m.group(0).replace("\t", " " * sp["indent"])
        return ws + line[m.end():]
    if kind == "eq_cond":
        c = issue.col
        if c < len(line) and line[c] == "=":
            return line[:c] + "==" + line[c + 1:]
        return None
    if kind == "span":
        c1, c2, rep = data
        if 0 <= c1 <= c2 <= len(line):
            new = line[:c1] + rep + line[c2:]
            return new if new != line else None
        return None
    return None


def outline_items(text, lang_id, limit=600):
    """Build a compact table-of-contents for a source buffer."""
    out = []
    sp = LANGS.get(lang_id, LANGS["text"])
    unit = max(1, sp.get("indent", 4))

    def level_of(line):
        raw = line[:len(line) - len(line.lstrip(" \t"))]
        width = 0
        for ch in raw:
            width += unit if ch == "\t" else 1
        return min(8, width // unit)

    def add(line_no, level, kind, name):
        name = re.sub(r"\s+", " ", name.strip())
        if name and len(out) < limit:
            out.append(OutlineItem(line_no, level, kind, name[:96]))

    for line_no, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if (not stripped or stripped.startswith(("//", "/*", "*", "--"))
                or (lang_id != "markdown" and stripped.startswith("#"))):
            continue
        level = level_of(line)
        m = None

        if lang_id == "python":
            m = re.match(r"^\s*(async\s+def|def|class)\s+([A-Za-z_]\w*)", line)
            if m:
                add(line_no, level, m.group(1), m.group(2))
                continue
        elif lang_id == "markdown":
            m = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
            if m:
                add(line_no, len(m.group(1)) - 1, "heading", m.group(2))
                continue
        elif lang_id in ("html",):
            m = re.match(r"^\s*<\s*(h[1-6]|section|article|main|nav|div)\b([^>]*)>", line, re.I)
            if m:
                attrs = m.group(2)
                label = m.group(1).lower()
                ident = re.search(r"\b(?:id|class)\s*=\s*['\"]([^'\"]+)['\"]", attrs)
                add(line_no, level, "tag", label + ((" #" + ident.group(1)) if ident else ""))
                continue
        elif lang_id in ("css",):
            if stripped.endswith("{"):
                add(line_no, level, "rule", stripped[:-1].strip())
                continue
        elif lang_id == "sql":
            m = re.match(r"^\s*create\s+(table|view|index|trigger|function|procedure)\s+([A-Za-z_][\w.]*)", line, re.I)
            if m:
                add(line_no, level, m.group(1).lower(), m.group(2))
                continue

        m = re.match(r"^\s*(?:export\s+|public\s+|private\s+|protected\s+|internal\s+|open\s+|final\s+|abstract\s+|sealed\s+|data\s+|static\s+)*(class|interface|enum|struct|record|object|trait)\s+([A-Za-z_$][\w$]*)", line)
        if m:
            add(line_no, level, m.group(1), m.group(2))
            continue
        m = re.match(r"^\s*(?:export\s+|async\s+|suspend\s+|static\s+)*(func|fun|function|def|fn)\s+(?:\([^)]*\)\s*)?([A-Za-z_$][\w$]*)", line)
        if m:
            add(line_no, level, m.group(1), m.group(2))
            continue
        if lang_id in ("c", "cpp", "java", "csharp", "go", "rust", "swift", "kotlin"):
            m = re.match(r"^\s*(?:[A-Za-z_$][\w$<>\[\],.?*&:\s]+\s+)+([A-Za-z_$][\w$]*)\s*\([^;{}]*\)\s*(?:\{|=>)?\s*$", line)
            if m and m.group(1) not in ("if", "for", "while", "switch", "catch"):
                add(line_no, level, "method", m.group(1))

    return out


# ==========================================================================
# GeckoFix - the deep repair engine.
#
# "Fix Everything" runs repair ROUNDS until the file is clean or stable:
#   round = normalize unicode punctuation  (curly quotes, full-width ; : ,)
#         + apply every fixable issue from the fast checker
#         + language-specific repair:
#             Python : drive the real parser - each SyntaxError message is
#                      dispatched to a targeted repair (colons, commas,
#                      '=' vs '==', indentation, strings, print, ...); once
#                      it parses, semantic repairs run (typo renames via
#                      fuzzy match, auto-import of stdlib modules, unused-
#                      import removal).
#             C/C++  : compile with clang/gcc "-fdiagnostics-parseable-
#                      fixits" and apply the compiler's own machine-readable
#                      edits (missing ';', typo suggestions, '.'->'->', ...).
#             others : re-run the external checker and apply its fixables.
#         + when the file finally parses/compiles: normalize layout
#           (indentation snapped to the language grid, trailing whitespace).
# Entirely offline - the "intelligence" is the language's own toolchain
# plus a large hand-written repair catalog. No APIs, no internet.
# ==========================================================================

WORD_RE_FIX = r"[A-Za-z_][A-Za-z0-9_]*"

UNICODE_PUNCT = {
    "“": '"', "”": '"', "„": '"', "″": '"',
    "‘": "'", "’": "'", "‚": "'", "′": "'",
    "＂": '"', "＇": "'",
    "（": "(", "）": ")", "［": "[", "］": "]",
    "｛": "{", "｝": "}",
    "，": ",", "；": ";", "：": ":", "．": ".",
    "！": "!", "？": "?", "＝": "=", "＋": "+",
    "－": "-", "＊": "*", "／": "/", "＜": "<",
    "＞": ">", "、": ",", "。": ".",
    "–": "-", "—": "-", "−": "-",
    " ": " ", "　": " ",
}


def normalize_unicode_punct(text, lang_id):
    """Replace curly quotes / full-width punctuation with ASCII, everywhere
    except inside VALID strings and comments (a broken smart-quoted string is
    not tokenized as a string, so its delimiters do get repaired)."""
    if not (set(text) & set(UNICODE_PUNCT)):
        return text
    protected = []
    try:
        for s, e, tt in tokenize(text, lang_id):
            if tt in ("string", "comment", "codeblock"):
                protected.append((s, e))
    except Exception:
        pass
    out = list(text)
    pi = 0
    for i, ch in enumerate(out):
        rep = UNICODE_PUNCT.get(ch)
        if rep is None:
            continue
        while pi < len(protected) and protected[pi][1] <= i:
            pi += 1
        if pi < len(protected) and protected[pi][0] <= i < protected[pi][1]:
            continue
        out[i] = rep
    return "".join(out)


def apply_text_edits(text, edits):
    """Apply [(l1,c1,l2,c2,replacement)] with 1-based lines and 1-based BYTE
    columns (clang's convention). Bottom-up; overlapping edits skipped."""
    blob = text.encode("utf-8")
    lines = blob.split(b"\n")
    starts = [0]
    for ln in lines[:-1]:
        starts.append(starts[-1] + len(ln) + 1)
    spans = []
    for (l1, c1, l2, c2, rep) in edits:
        if not (1 <= l1 <= len(lines) and 1 <= l2 <= len(lines)):
            continue
        a = starts[l1 - 1] + max(0, c1 - 1)
        b = starts[l2 - 1] + max(0, c2 - 1)
        if a > b or b > len(blob):
            continue
        spans.append((a, b, rep.encode("utf-8")))
    spans.sort(key=lambda s: (-s[0], -s[1]))
    prev_start = None
    for a, b, rep in spans:
        if prev_start is not None and b > prev_start:
            continue
        blob = blob[:a] + rep + blob[b:]
        prev_start = a
    return blob.decode("utf-8", "replace")


def apply_issue_fixes_text(text, lang_id, issues=None):
    """Apply every fixable issue from the fast checker to plain text."""
    sp = LANGS[lang_id]
    if issues is None:
        try:
            issues = check_source(text, lang_id)
        except Exception:
            return text, []
    fixables = [i for i in issues if i.fix]
    if not fixables:
        return text, []
    lines = text.split("\n")
    notes = []
    for iss in sorted(fixables, key=lambda i: (-i.line, -i.col)):
        kind, data = iss.fix
        if kind == "append_eof":
            lines[-1] = lines[-1] + data
            notes.append("end of file: closed with %s" % data)
            continue
        if not (1 <= iss.line <= len(lines)):
            continue
        old = lines[iss.line - 1]
        if kind == "rename_class":
            if iss.end <= len(old):
                new = old[:iss.col] + data + old[iss.end:]
            else:
                new = None
        else:
            new = fixed_line_text(old, iss, sp)
        if new is not None and new != old:
            lines[iss.line - 1] = new
            notes.append("line %d: %s" % (iss.line, iss.msg))
    return "\n".join(lines), notes


# ---- Python: parser-driven syntax repair ---------------------------------

_HDR_LINE_RE = re.compile(r"on line (\d+)")


def _indent_of(line):
    m = re.match(r"[ \t]*", line)
    return m.group(0).replace("\t", "    ")


def py_syntax_fix_round(text):
    """Ask the real parser what is wrong and repair that one thing.
    Returns (new_text, [notes]); unchanged text means nothing was done."""
    try:
        ast.parse(text)
        return text, []
    except SyntaxError as exc:
        err = exc
    return _py_dispatch(text, err)


def _py_missing_comma_guess(masked, depth0):
    """Column to insert ',' between two adjacent atoms inside brackets,
    or None. Works without any error-message hint (Python 3.9 says only
    'invalid syntax' for `[1 2]`)."""
    depth = depth0
    in_str = None
    prev_atom_end = None
    i = 0
    n = len(masked)
    while i < n:
        c = masked[i]
        if c in "([{":
            depth += 1
            prev_atom_end = None
        elif c in ")]}":
            depth -= 1
            prev_atom_end = i + 1
        elif depth > 0:
            if c.isspace():
                i += 1
                continue
            m = re.match(r"[A-Za-z_0-9.]+|\"[^\"]*\"|'[^']*'", masked[i:])
            if m:
                word = m.group(0)
                if (prev_atom_end is not None
                        and word not in ("for", "in", "if", "else", "not",
                                         "and", "or", "is", "None", "True",
                                         "False", "lambda")
                        and masked[prev_atom_end:i].strip() == ""
                        and i > prev_atom_end):
                    return prev_atom_end
                i += len(word)
                prev_atom_end = i
                continue
            prev_atom_end = None
        i += 1
    return None


def _py_dispatch(text, err):
    """Message-driven repair, with structural fallbacks so it also works on
    old Pythons (Apple ships 3.9, which says only 'invalid syntax')."""
    ln = err.lineno or 1
    col = max(0, (err.offset or 1) - 1)
    msg = (err.msg or "").lower()
    lines = text.split("\n")
    if ln - 1 >= len(lines):
        ln = len(lines)
    cur = lines[ln - 1] if lines else ""

    def note(t):
        new_text = "\n".join(lines)
        if new_text == text:
            return text, []
        return new_text, ["line %d: %s" % (ln, t)]

    # 1 2  ->  1, 2
    if "forgot a comma" in msg:
        k = col
        while k < len(cur) and (cur[k].isalnum() or cur[k] in "_\"'.)]}"):
            k += 1
        lines[ln - 1] = cur[:k] + "," + cur[k:]
        return note("inserted the missing ','")

    # if x = 1  ->  if x == 1
    if "maybe you meant '=='" in msg or "cannot assign to" in msg:
        masked, _ = split_code_comment(cur, "#")
        m = re.search(r"(?<![=!<>+\-*/%&|^])=(?![=])", masked)
        if m:
            lines[ln - 1] = cur[:m.start()] + "==" + cur[m.start() + 1:]
            return note("changed '=' to '==' (comparison)")

    # def f():\nx = 1  ->  indent the body (or add pass)
    if "expected an indented block" in msg:
        hm = _HDR_LINE_RE.search(err.msg or "")
        hdr = int(hm.group(1)) if hm else max(1, ln - 1)
        want = _indent_of(lines[hdr - 1]) + "    " if hdr - 1 < len(lines) \
            else "    "
        if ln - 1 < len(lines) and lines[ln - 1].strip():
            lines[ln - 1] = want + lines[ln - 1].lstrip()
            return note("indented this line under the block on line %d" % hdr)
        lines.insert(hdr, want + "pass")
        return note("added 'pass' so the empty block on line %d is valid" % hdr)

    # stray extra indentation
    if "unexpected indent" in msg:
        prev = ""
        for k in range(ln - 2, -1, -1):
            if lines[k].strip():
                prev = lines[k]
                break
        base = _indent_of(prev)
        code_prev = split_code_comment(prev, "#")[0].rstrip()
        if code_prev.endswith(":"):
            base += "    "
        lines[ln - 1] = base + lines[ln - 1].lstrip()
        return note("re-aligned this line's indentation")

    # dedent that matches no outer level: try candidate repairs and keep the
    # first one the parser accepts (or that at least moves past this error)
    if "unindent does not match" in msg:
        w = len(_indent_of(cur))
        stack = [0]
        for k in range(ln - 1):
            l = lines[k]
            if not l.strip():
                continue
            lw = len(_indent_of(l))
            if lw > stack[-1]:
                stack.append(lw)
            else:
                while len(stack) > 1 and stack[-1] > lw:
                    stack.pop()
        cands = []
        # A: snap this line to the nearest open block level (tie -> deeper,
        #    so a `return` stays inside its function)
        near = min(stack, key=lambda s: (abs(s - w), -s))
        a = list(lines)
        a[ln - 1] = " " * near + cur.lstrip()
        cands.append((a, "snapped this line to the enclosing block level"))
        # B: the PREVIOUS line was the over-indented one - align it with its
        #    own block header + one indent
        pk = ln - 2
        while pk >= 0 and not lines[pk].strip():
            pk -= 1
        if pk >= 0:
            pw = len(_indent_of(lines[pk]))
            hk = pk - 1
            while hk >= 0:
                l = lines[hk]
                if l.strip() and len(_indent_of(l)) < pw:
                    break
                hk -= 1
            if hk >= 0:
                want = _indent_of(lines[hk]) + "    "
                b = list(lines)
                b[pk] = want + lines[pk].lstrip()
                cands.append((b, "re-aligned the over-indented line %d"
                              % (pk + 1)))
        for cand, why in cands:
            new_text = "\n".join(cand)
            if new_text == text:
                continue
            try:
                ast.parse(new_text)
                return new_text, ["line %d: %s" % (ln, why)]
            except SyntaxError as e2:
                if (e2.lineno, (e2.msg or "").lower()[:20]) != \
                        (ln, msg[:20]):
                    return new_text, ["line %d: %s" % (ln, why)]
        return text, []

    # "x = "abc   ->   x = "abc"
    if ("unterminated string literal" in msg
            or "eol while scanning string literal" in msg):
        q = cur[col] if col < len(cur) and cur[col] in "\"'" else "\""
        lines[ln - 1] = cur + q
        return note("closed the string with %s" % q)

    if "unterminated triple-quoted" in msg:
        q = '"""' if '"""' in text else "'''"
        lines[-1] = lines[-1] + ("\n" if lines[-1].strip() else "") + q
        return note("closed the triple-quoted string")

    # ---- structural fallbacks: old Pythons (Apple ships 3.9) say only
    # "invalid syntax" for many of the above, so diagnose the line ourselves.
    if "invalid syntax" in msg or "cannot assign" in msg:
        toks = tokenize(text, "python")
        li = LineIndex(text)
        masked = _masked(text, li, ln,
                         [t for t in toks if li.line_col(t[0])[0] == ln], cur)
        # a) '=' where '==' was meant, in a condition
        if re.match(r"^\s*(if|while|elif)\b", masked):
            m2 = re.search(r"(?<![=!<>+\-*/%&|^])=(?![=])", masked)
            if m2:
                lines[ln - 1] = (cur[:m2.start()] + "=="
                                 + cur[m2.start() + 1:])
                return note("changed '=' to '==' (comparison)")
        # b) missing ',' between adjacent items inside brackets
        _, _, _, events = scan_brackets(text, toks)
        depths = depth_at_line_starts(li.starts, events)
        d0 = depths[ln - 1] if ln - 1 < len(depths) else 0
        at = _py_missing_comma_guess(masked, d0)
        if at is not None and at <= len(cur):
            lines[ln - 1] = cur[:at] + "," + cur[at:]
            return note("inserted the missing ','")

    # anything the fast checker already knows how to fix (missing ':',
    # unclosed brackets, python-2 print, tabs...) is handled by the caller.
    return text, []


def _py_scan_names(tree):
    """(defined, used{name:(line,col)}, imports[{...}], star) for a module."""
    defined = set()
    used = {}
    imports = []
    star = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                nm = a.asname or a.name.split(".")[0]
                defined.add(nm)
                imports.append({"alias": nm, "module": a.name,
                                "line": node.lineno, "from": None})
        elif isinstance(node, ast.ImportFrom):
            if node.module == "__future__":
                continue
            for a in node.names:
                if a.name == "*":
                    star = True
                    continue
                nm = a.asname or a.name
                defined.add(nm)
                imports.append({"alias": nm, "module": a.name,
                                "line": node.lineno, "from": node.module})
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef,
                               ast.ClassDef)):
            defined.add(node.name)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            defined.add(node.name)
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            defined.update(node.names)
        elif isinstance(node, ast.arg):
            defined.add(node.arg)
        elif isinstance(node, ast.Name):
            if isinstance(node.ctx, (ast.Store, ast.Del)):
                defined.add(node.id)
            else:
                used.setdefault(node.id, (node.lineno, node.col_offset))
        elif _MatchAs and isinstance(node, _MatchAs) and node.name:
            defined.add(node.name)
        elif _MatchStar and isinstance(node, _MatchStar) and node.name:
            defined.add(node.name)
        elif _MatchMapping and isinstance(node, _MatchMapping) and node.rest:
            defined.add(node.rest)
    return defined, used, imports, star


def rename_word(text, lang_id, old, new):
    """Replace whole-word occurrences of `old` outside strings/comments."""
    protected = []
    try:
        for s, e, tt in tokenize(text, lang_id):
            if tt in ("string", "comment", "codeblock"):
                protected.append((s, e))
    except Exception:
        pass

    def shielded(pos):
        for s, e in protected:
            if s <= pos < e:
                return True
        return False
    out = []
    last = 0
    for m in re.finditer(r"\b%s\b" % re.escape(old), text):
        if shielded(m.start()):
            continue
        out.append(text[last:m.start()])
        out.append(new)
        last = m.end()
    out.append(text[last:])
    return "".join(out)


def _import_insert_line(lines):
    """Best line index for a new import: after shebang/docstring/imports."""
    i = 0
    n = len(lines)
    if i < n and lines[i].startswith("#!"):
        i += 1
    while i < n and (not lines[i].strip() or lines[i].lstrip().startswith("#")):
        i += 1
    if i < n and re.match(r'\s*[rRbBuUfF]*("""|\'\'\')', lines[i]):
        q = re.search(r'("""|\'\'\')', lines[i]).group(1)
        rest = lines[i].split(q, 1)[1]
        if q not in rest:
            i += 1
            while i < n and q not in lines[i]:
                i += 1
        i += 1
    while i < n and (not lines[i].strip()
                     or re.match(r"\s*(import|from)\s", lines[i])):
        i += 1
    return i


def py_semantic_fix_round(text):
    """Typo renames, stdlib auto-imports, unused-import removal.
    Only runs when the module parses. Returns (new_text, notes)."""
    import difflib
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return text, []
    notes = []
    defined, used, imports, star = _py_scan_names(tree)
    if star:
        return text, []
    kw_set = set(__import__("keyword").kwlist)

    # a) undefined names: auto-import stdlib modules, else fuzzy-rename typos
    for name in sorted(used):
        if name in defined or name in _PY_BUILTINS:
            continue
        if name in _SAFE_STDLIB:
            lines = text.split("\n")
            at = _import_insert_line(lines)
            lines.insert(at, "import %s" % name)
            notes.append("added the missing 'import %s'" % name)
            return "\n".join(lines), notes
        pool = sorted((defined | _PY_BUILTINS | _SAFE_STDLIB) - kw_set)
        cand = difflib.get_close_matches(name, pool, n=1, cutoff=0.8)
        if not cand and len(name) >= 4:
            cand = difflib.get_close_matches(name, pool, n=1, cutoff=0.72)
        if cand and cand[0] != name:
            fixed = rename_word(text, "python", name, cand[0])
            if fixed != text:
                notes.append("renamed '%s' to '%s' (typo)" % (name, cand[0]))
                return fixed, notes

    # b) unused imports: drop them
    used_names = set(used)
    lines = text.split("\n")
    for imp in imports:
        nm = imp["alias"]
        if nm.startswith("_") or nm in used_names or "__all__" in defined:
            continue
        li = imp["line"] - 1
        if not (0 <= li < len(lines)):
            continue
        raw = lines[li]
        names_on_line = [i for i in imports if i["line"] == imp["line"]]
        if len(names_on_line) == 1:
            del lines[li]
        else:
            new = re.sub(r"(,\s*%s\b(\s+as\s+\w+)?)|(\b%s\b(\s+as\s+\w+)?\s*,\s*)"
                         % (re.escape(imp["module"].split(".")[0] if not imp["from"] else nm),
                            re.escape(imp["module"] if not imp["from"] else nm)),
                         "", raw, count=1)
            if new == raw:
                continue
            lines[li] = new
        notes.append("removed unused import '%s'" % nm)
        return "\n".join(lines), notes
    return text, notes


# ---- C/C++: apply the compiler's own machine-readable fix-its ------------

_FIXIT_RE = re.compile(
    r'^fix-it:"([^"]*)":\{(\d+):(\d+)-(\d+):(\d+)\}:"((?:[^"\\]|\\.)*)"')


def clang_fix_edits(lang_id, text):
    """One compile pass with -fdiagnostics-parseable-fixits.
    Returns (edits, notes) - the compiler's exact repairs."""
    tool = linter_tool(lang_id)
    if not tool or lang_id not in ("c", "cpp"):
        return [], []
    d = tempfile.mkdtemp(prefix="geskofix-")
    try:
        path = os.path.join(d, "buffer" + LANGS[lang_id]["exts"][0])
        with open(path, "w", encoding="utf-8") as f:
            f.write(text if text.endswith("\n") else text + "\n")
        argv = [tool, "-fsyntax-only", "-fdiagnostics-parseable-fixits",
                "-std=c11" if lang_id == "c" else "-std=c++17", path]
        try:
            proc = subprocess.run(argv, cwd=d, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True,
                                  timeout=12, errors="replace")
        except (subprocess.TimeoutExpired, OSError):
            return [], []
        edits, notes = [], []
        last = ""
        base = os.path.basename(path)
        for line in (proc.stdout or "").splitlines():
            dm = _DIAG_FULL.match(line)
            if dm and dm.group("s") != "note":
                last = "line %s: %s" % (dm.group("l"), dm.group("m").strip())
            fm = _FIXIT_RE.match(line)
            if fm and os.path.basename(fm.group(1)) == base:
                try:
                    rep = fm.group(6).encode("utf-8").decode("unicode_escape")
                except Exception:
                    rep = fm.group(6)
                edits.append((int(fm.group(2)), int(fm.group(3)),
                              int(fm.group(4)), int(fm.group(5)), rep))
                if last:
                    notes.append(last)
                    last = ""
        return edits, notes
    except Exception as ex:
        _log_error("clang_fix_edits", ex)
        return [], []
    finally:
        shutil.rmtree(d, ignore_errors=True)


def external_fix_round(lang_id, text):
    """Apply fixable diagnostics from the language's own checker."""
    diags = run_linter(lang_id, text)
    issues = [Issue(l, c, c + 1, sev, msg, fix)
              for (l, c, sev, msg, fix) in diags if fix]
    if not issues:
        return text, []
    return apply_issue_fixes_text(text, lang_id, issues)


# ---- layout: indentation + whitespace normalization -----------------------

def strip_trailing_ws(text, lang_id):
    """Strip trailing spaces (not inside multiline strings); final newline."""
    protected_lines = set()
    try:
        li = LineIndex(text)
        for s, e, tt in tokenize(text, lang_id):
            if tt in ("string", "codeblock") and "\n" in text[s:e]:
                a = li.line_col(s)[0]
                b = li.line_col(e - 1)[0]
                for k in range(a, b + 1):
                    protected_lines.add(k)
    except Exception:
        pass
    lines = text.split("\n")
    for i in range(len(lines)):
        if (i + 1) not in protected_lines:
            lines[i] = lines[i].rstrip()
    out = "\n".join(lines)
    if out.strip():
        if len(lines) not in protected_lines:
            out = out.rstrip("\n")
        if not out.endswith("\n"):
            out += "\n"
    return out


def reindent_python(text):
    """Snap indentation to the 4-space grid. Only returns a changed text if
    the input parsed AND the output still parses to the same tree."""
    try:
        before = ast.dump(ast.parse(text))
    except SyntaxError:
        return text
    toks = tokenize(text, "python")
    li = LineIndex(text)
    _, _, _, events = scan_brackets(text, toks)
    depths = depth_at_line_starts(li.starts, events)
    ml_lines = set()
    for s, e, tt in toks:
        if tt in ("string", "comment") and "\n" in text[s:e]:
            a = li.line_col(s)[0]
            b = li.line_col(e - 1)[0]
            for k in range(a + 1, b + 1):
                ml_lines.add(k)
    lines = text.split("\n")
    out = []
    stack = [0]
    levels = {0: 0}
    prev_colon = False
    for idx, raw in enumerate(lines):
        n = idx + 1
        if n in ml_lines or depths[idx] > 0 or not raw.strip():
            out.append(raw)
            continue
        w = len(_indent_of(raw))
        if prev_colon:
            new_level = levels[stack[-1]] + 1
            if w > stack[-1]:
                stack.append(w)
                levels[w] = new_level
            else:
                stack.append(w + 4)
                levels[w + 4] = new_level
                w = w + 4
        else:
            while len(stack) > 1 and w < stack[-1]:
                stack.pop()
            if w != stack[-1]:
                w = stack[-1]
        target = levels.get(stack[-1], 0) * 4
        out.append(" " * target + raw.lstrip())
        code = split_code_comment(raw, "#")[0].rstrip()
        prev_colon = code.endswith(":")
    result = "\n".join(out)
    try:
        if ast.dump(ast.parse(result)) == before:
            return result
    except SyntaxError:
        pass
    return text


def reindent_braces(text, lang_id):
    """Brace/paren-driven reindent for C-family languages (whitespace is
    insignificant there, so this is always safe)."""
    sp = LANGS[lang_id]
    unit = indent_unit(sp)
    toks = tokenize(text, lang_id)
    li = LineIndex(text)
    _, _, _, events = scan_brackets(text, toks)
    depths = depth_at_line_starts(li.starts, events)
    ml_lines = set()
    for s, e, tt in toks:
        if tt in ("string", "comment", "codeblock") and "\n" in text[s:e]:
            a = li.line_col(s)[0]
            b = li.line_col(e - 1)[0]
            for k in range(a + 1, b + 1):
                ml_lines.add(k)
    lines = text.split("\n")
    out = []
    for idx, raw in enumerate(lines):
        n = idx + 1
        st = raw.strip()
        if n in ml_lines or not st or st.startswith("#"):
            out.append(raw)
            continue
        d = depths[idx]
        k = 0
        while k < len(st) and st[k] in ")]}":
            d -= 1
            k += 1
        if re.match(r"^(case\b.*|default\s*):", st):
            d = max(0, d)  # keep switch labels at body depth
        d = max(0, d)
        out.append(unit * d + st)
    return "\n".join(out)


def reindent_html(text):
    """Indent markup by tag depth (2 spaces); raw blocks left untouched."""
    try:
        _, _, _ = html_scan(text)
    except Exception:
        return text
    lines = text.split("\n")
    li = LineIndex(text)
    # depth at each line start, walking tags in order
    depth = 0
    line_depth = [0] * (len(lines) + 1)
    raw_lines = set()
    raw_until = None
    events = []
    for m in _HTML_TAG_RE.finditer(text):
        closing, name, attrs, selfclose = m.groups()
        lname = name.lower()
        if raw_until:
            if closing and lname == raw_until:
                raw_until = None
                events.append((m.start(), -1))
            continue
        if closing:
            events.append((m.start(), -1))
        elif lname in HTML_VOID or selfclose:
            pass
        else:
            events.append((m.end(), +1))
            if lname in HTML_RAW:
                raw_until = lname
    for sm in _HTML_SKIP_RE.finditer(text):
        a = li.line_col(sm.start())[0]
        b = li.line_col(max(sm.start(), sm.end() - 1))[0]
        for k in range(a + 1, b + 1):
            raw_lines.add(k)
    ei = 0
    events.sort()
    for ln in range(1, len(lines) + 1):
        start = li.starts[ln - 1]
        while ei < len(events) and events[ei][0] < start:
            depth = max(0, depth + events[ei][1])
            ei += 1
        line_depth[ln] = depth
    out = []
    raw_mode = False
    for i, raw in enumerate(lines):
        n = i + 1
        st = raw.strip()
        low = st.lower()
        if re.match(r"<(script|style|pre|textarea)\b", low):
            raw_mode = True
            out.append("  " * line_depth[n] + st if st else raw)
            continue
        if raw_mode:
            out.append(raw)
            if re.search(r"</(script|style|pre|textarea)>", low):
                raw_mode = False
            continue
        if not st or n in raw_lines:
            out.append(raw if n in raw_lines else "")
            continue
        d = line_depth[n]
        if st.startswith("</"):
            d = max(0, d - 1)
        out.append("  " * d + st)
    return "\n".join(out)


GO_PACKAGE_RE = re.compile(r"^[ \t]*package[ \t]+\w+[ \t]*$")
GO_IMPORT_ONE = re.compile(r"^[ \t]*import[ \t]+(?:\w+[ \t]+)?\"[^\"]*\"")
GO_IMPORT_OPEN = re.compile(r"^[ \t]*import[ \t]*\(")


def go_structure_fix(text):
    """Go requires: package clause first, then imports, then declarations.
    A file whose pieces got shuffled violates that - put them back."""
    lines = text.split("\n")
    pkg_idx = [i for i, l in enumerate(lines) if GO_PACKAGE_RE.match(l)]
    if not pkg_idx:
        return text, []
    imports = []          # (start, end) inclusive line spans
    i = 0
    while i < len(lines):
        if GO_IMPORT_ONE.match(lines[i]):
            imports.append((i, i))
        elif GO_IMPORT_OPEN.match(lines[i]):
            j = i
            while j < len(lines) and ")" not in lines[j]:
                j += 1
            imports.append((i, min(j, len(lines) - 1)))
            i = j
        i += 1
    first_code = None
    first_decl = len(lines)
    for i, l in enumerate(lines):
        st = l.strip()
        if not st or st.startswith("//"):
            continue
        if first_code is None:
            first_code = i
        if (not GO_PACKAGE_RE.match(l)
                and not any(a <= i <= b for a, b in imports)
                and first_decl == len(lines)):
            first_decl = i
    ok = (first_code == pkg_idx[0] and len(pkg_idx) == 1
          and all(b < first_decl for a, b in imports))
    if ok:
        return text, []
    taken = set()
    pkg_line = lines[pkg_idx[0]]
    taken.add(pkg_idx[0])
    import_lines = []
    for a, b in imports:
        for k in range(a, b + 1):
            if k not in taken:
                import_lines.append(lines[k])
                taken.add(k)
    rest = [l for i, l in enumerate(lines)
            if i not in taken and not GO_PACKAGE_RE.match(l)]
    while rest and not rest[0].strip():
        rest.pop(0)
    while rest and not rest[-1].strip():
        rest.pop()
    out = [pkg_line, ""]
    if import_lines:
        out += import_lines + [""]
    out += rest
    new = "\n".join(out)
    if new == text:
        return text, []
    return new, ["moved 'package' to the top and imports after it "
                 "(Go requires that order)"]


# ---- JSON: full offline repair driven by the real parser -----------------

def _sq_to_dq(text, pos):
    """Convert the single-quoted string starting at text[pos] to double."""
    j = pos + 1
    buf = []
    while j < len(text):
        c = text[j]
        if c == "\\" and j + 1 < len(text):
            nxt = text[j + 1]
            buf.append("'" if nxt == "'" else c + nxt)
            j += 2
            continue
        if c == "'":
            inner = "".join(buf).replace('"', '\\"')
            return text[:pos] + '"' + inner + '"' + text[j + 1:]
        buf.append(c)
        j += 1
    return None


def json_fix_round(text):
    """One repair per round, told to us by json.loads itself."""
    if not text.strip():
        return text, []
    try:
        json.loads(text)
        return text, []
    except json.JSONDecodeError as exc:
        err = exc
    pos = max(0, min(err.pos, len(text)))
    ch = text[pos] if pos < len(text) else ""
    msg = err.msg

    def note(new, what):
        if new is None or new == text:
            return text, []
        return new, ["line %d: %s" % (err.lineno, what)]

    def drop_prev_comma(p):
        k = p - 1
        while k >= 0 and text[k] in " \t\r\n":
            k -= 1
        if k >= 0 and text[k] == ",":
            return text[:k] + text[k + 1:]
        return None

    if "Expecting ',' delimiter" in msg:
        return note(text[:pos] + "," + text[pos:], "inserted the missing ','")
    if "Expecting ':' delimiter" in msg:
        return note(text[:pos] + ":" + text[pos:], "inserted the missing ':'")
    if "trailing comma" in msg.lower():        # Python 3.13+ wording
        if ch == ",":
            return note(text[:pos] + text[pos + 1:],
                        "removed the trailing ','")
        return note(drop_prev_comma(pos), "removed the trailing ','")
    if "Expecting property name" in msg:
        if ch == "'":
            return note(_sq_to_dq(text, pos),
                        "JSON strings use double quotes - converted")
        if ch == "}":
            return note(drop_prev_comma(pos), "removed the trailing ','")
        m = re.match(r"[A-Za-z_][\w-]*", text[pos:])
        if m:
            return note(text[:pos] + '"%s"' % m.group(0)
                        + text[pos + m.end():], "quoted the bare key")
    if "Expecting value" in msg:
        if ch == "'":
            return note(_sq_to_dq(text, pos),
                        "JSON strings use double quotes - converted")
        m = re.match(r"(True|False|None|NaN|-?Infinity|undefined)\b",
                     text[pos:])
        if m:
            rep = {"True": "true", "False": "false", "None": "null",
                   "NaN": "null", "Infinity": "null", "-Infinity": "null",
                   "undefined": "null"}[m.group(1)]
            return note(text[:pos] + rep + text[pos + m.end():],
                        "JSON spells this '%s'" % rep)
        if ch in "]}":
            return note(drop_prev_comma(pos), "removed the trailing ','")
        if ch == "/" or text.lstrip().startswith("//"):
            new = re.sub(r"(?m)//[^\n]*", "", text)
            new = re.sub(r"/\*.*?\*/", "", new, flags=re.S)
            return note(new, "removed // comments (not allowed in JSON)")
        if pos >= len(text.rstrip()):
            toks = tokenize(text, "json")
            _, unclosed, _, _ = scan_brackets(text, toks)
            if unclosed:
                closers = "".join(BRK_PAIR[c] for _, c in reversed(unclosed))
                return note(text.rstrip("\n") + closers + "\n",
                            "closed with '%s'" % closers)
    if "Unterminated string" in msg:
        li = LineIndex(text)
        lines = text.split("\n")
        if err.lineno - 1 < len(lines):
            lines[err.lineno - 1] += '"'
            return note("\n".join(lines), "closed the string")
    if "Invalid \\escape" in msg and pos < len(text):
        return note(text[:pos] + "\\" + text[pos:], "escaped the backslash")
    if "Invalid control character" in msg and pos < len(text):
        rep = "\\n" if text[pos] == "\n" else ""
        return note(text[:pos] + rep + text[pos + 1:],
                    "escaped a raw control character inside the string")
    return text, []


# ---- CSS ------------------------------------------------------------------

def css_fix_round(text):
    toks = tokenize(text, "css")
    for s, e, tt in toks:
        if tt == "comment" and not text[s:e].rstrip().endswith("*/"):
            # Close the comment at the end of ITS OWN line, so the code
            # below it is not swallowed into the comment.
            nl = text.find("\n", s)
            if nl == -1:
                nl = len(text)
            return (text[:nl] + " */" + text[nl:],
                    ["closed the unterminated /* comment"])
    li = LineIndex(text)
    _, _, _, events = scan_brackets(text, toks)
    depths = depth_at_line_starts(li.starts, events)
    lines = text.split("\n")
    notes = []
    for i, raw in enumerate(lines):
        st = raw.rstrip()
        body = st.strip()
        if depths[i] < 1 or not body:
            continue
        if (re.match(r"^[\w-]+\s*:", body)
                and not body.endswith((";", "{", "}", ","))):
            nxt = ""
            for k in range(i + 1, len(lines)):
                if lines[k].strip():
                    nxt = lines[k].strip()
                    break
            if not nxt or nxt.startswith("}") or re.match(r"^[\w-]+\s*:", nxt):
                lines[i] = st + ";"
                notes.append("line %d: added the missing ';'" % (i + 1))
    return ("\n".join(lines), notes) if notes else (text, [])


# ---- YAML -----------------------------------------------------------------

def yaml_fix_round(text):
    notes = []
    out = []
    for i, raw in enumerate(text.split("\n")):
        line = raw
        m = re.match(r"^([ ]*)(\t+)", line)
        if m:
            line = line.replace("\t", "  ", line.count("\t"))
            notes.append("line %d: YAML forbids tabs - converted to spaces"
                         % (i + 1))
        new = re.sub(r"^(\s*(?:- )?[\w.$-]+):(?!//)(\S)", r"\1: \2", line)
        if new != line:
            notes.append("line %d: added the space YAML needs after ':'"
                         % (i + 1))
            line = new
        out.append(line)
    return ("\n".join(out), notes) if notes else (text, [])


# ---- Markdown ---------------------------------------------------------------

def markdown_fix_round(text):
    notes = []
    fences = len(re.findall(r"(?m)^```", text))
    if fences % 2 == 1:
        text = text.rstrip("\n") + "\n```\n"
        notes.append("closed the unterminated ``` code fence")
    new = re.sub(r"(?m)^(#{1,6})([^#\s])", r"\1 \2", text)
    if new != text:
        notes.append("added the space headings need after '#'")
        text = new
    return text, notes


# ---- keyword/end balance repair (Ruby, Lua, Shell) -------------------------

def _line_start_tok(text, li, s):
    ln, col = li.line_col(s)
    line = text[li.starts[ln - 1]:s]
    return line.strip() == ""


def ruby_end_fix(text):
    """Append the `end`s Ruby says are missing."""
    tool = which_tool("ruby")
    if tool:
        d = run_linter("ruby", text)
        if not d:
            return text, []
        if not any("end-of-input" in m or "expected `end" in m
                   or "expecting keyword_end" in m or "expecting end"
                   in m.lower() for _, _, _, m, _ in d):
            return text, []
    toks = tokenize(text, "ruby")
    li = LineIndex(text)
    bal = 0
    prev_line_opener = -1
    for s, e, tt in toks:
        if tt != "keyword":
            continue
        w = text[s:e]
        ln = li.line_col(s)[0]
        if w in ("def", "class", "module", "begin", "case"):
            bal += 1
            prev_line_opener = ln
        elif w in ("if", "unless", "while", "until", "for"):
            if _line_start_tok(text, li, s):
                bal += 1
                prev_line_opener = ln
        elif w == "do":
            if ln != prev_line_opener:
                bal += 1
        elif w == "end":
            bal -= 1
    if bal <= 0:
        return text, []
    bal = min(bal, 6)
    return (text.rstrip("\n") + "\n" + "\n".join(["end"] * bal) + "\n",
            ["added %d missing 'end'%s" % (bal, "" if bal == 1 else "s")])


def lua_end_fix(text):
    tool = which_tool("luac", "luac5.4", "luac5.3")
    if tool:
        d = run_linter("lua", text)
        if not d or not any("'end' expected" in m or "near <eof>" in m
                            for _, _, _, m, _ in d):
            return text, []
    toks = tokenize(text, "lua")
    li = LineIndex(text)
    bal = 0
    reps = 0
    prev_line_opener = -1
    for s, e, tt in toks:
        if tt != "keyword":
            continue
        w = text[s:e]
        ln = li.line_col(s)[0]
        if w in ("function", "if", "for", "while"):
            bal += 1
            prev_line_opener = ln
        elif w == "do":
            if ln != prev_line_opener:
                bal += 1
        elif w == "repeat":
            reps += 1
        elif w == "end":
            bal -= 1
        elif w == "until":
            reps -= 1
    notes = []
    if bal > 0:
        bal = min(bal, 6)
        text = text.rstrip("\n") + "\n" + "\n".join(["end"] * bal) + "\n"
        notes.append("added %d missing 'end'%s" % (bal, "" if bal == 1
                                                   else "s"))
    return text, notes


def shell_end_fix(text):
    sh = which_tool("bash", "sh")
    if sh:
        d = run_linter("shell", text)
        if not d or not any("unexpected end of file" in m
                            or "unexpected EOF" in m for _, _, _, m, _ in d):
            return text, []
    toks = tokenize(text, "shell")
    stack = []
    for s, e, tt in toks:
        if tt != "keyword":
            continue
        w = text[s:e]
        if w == "if":
            stack.append("fi")
        elif w == "do":
            stack.append("done")
        elif w == "case":
            stack.append("esac")
        elif w in ("fi", "done", "esac"):
            if stack and stack[-1] == w:
                stack.pop()
    if not stack:
        return text, []
    closers = list(reversed(stack))[:6]
    return (text.rstrip("\n") + "\n" + "\n".join(closers) + "\n",
            ["closed the open block%s with %s"
             % ("" if len(closers) == 1 else "s", " ".join(closers))])


def sql_fix_round(text):
    body = text.rstrip()
    if not body:
        return text, []
    lines = body.split("\n")
    last = ""
    for l in reversed(lines):
        st = l.strip()
        if st and not st.startswith("--"):
            last = st
            break
    if last and not last.endswith(";"):
        return (text.rstrip("\n").rstrip() + ";\n",
                ["added the ';' the last statement needs"])
    return text, []


LANG_FIXERS = {
    "json": json_fix_round,
    "css": css_fix_round,
    "yaml": yaml_fix_round,
    "markdown": markdown_fix_round,
    "ruby": ruby_end_fix,
    "lua": lua_end_fix,
    "shell": shell_end_fix,
    "sql": sql_fix_round,
}


FORMATTERS = {
    "go": ("gofmt",), "rust": ("rustfmt",),
    "c": ("clang-format",), "cpp": ("clang-format",),
}
BRACE_LANGS = {"c", "cpp", "java", "csharp", "javascript", "typescript",
               "go", "rust", "swift", "kotlin", "php", "css", "json"}


def format_source(text, lang_id):
    """Format a buffer: real formatter if installed, else built-in reindent.
    Returns (new_text, tool_name)."""
    for toolname in FORMATTERS.get(lang_id, ()):
        tool = which_tool(toolname)
        if not tool:
            continue
        try:
            argv = [tool]
            if toolname == "clang-format":
                argv += ["-style={BasedOnStyle: llvm, IndentWidth: 4}"]
            proc = subprocess.run(argv, input=text, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True,
                                  timeout=10, errors="replace")
            if proc.returncode == 0 and proc.stdout.strip():
                return strip_trailing_ws(proc.stdout, lang_id), toolname
        except (subprocess.TimeoutExpired, OSError):
            pass
    if lang_id == "python":
        return strip_trailing_ws(reindent_python(text), lang_id), "geckofix"
    if lang_id == "html":
        return strip_trailing_ws(reindent_html(text), lang_id), "geckofix"
    if lang_id in BRACE_LANGS:
        return strip_trailing_ws(reindent_braces(text, lang_id),
                                 lang_id), "geckofix"
    return strip_trailing_ws(text, lang_id), "geckofix"


# ---- the conductor --------------------------------------------------------

def fix_everything(text, lang_id, max_rounds=12, want_layout=True):
    """Iteratively repair a buffer until clean or stable.
    Returns (new_text, log_lines, remaining_issues)."""
    log = []
    if len(text) > 400000:
        return text, ["file too large for deep fixing"], []
    for _ in range(max_rounds):
        start = text

        t2 = normalize_unicode_punct(text, lang_id)
        if t2 != text:
            log.append("normalized curly quotes / full-width punctuation")
            text = t2

        # Built-in fixables. When a real compiler is present, leave the
        # guess-based repairs (like missing ';') to its precise fix-its.
        try:
            base = check_source(text, lang_id,
                                heuristics=linter_tool(lang_id) is None)
        except Exception:
            base = []
        text, notes = apply_issue_fixes_text(text, lang_id, base)
        log += notes

        fixer = LANG_FIXERS.get(lang_id)
        if fixer:
            try:
                text, notes = fixer(text)
                log += notes
            except Exception as ex:
                _log_error("lang_fixer:" + lang_id, ex)

        if lang_id == "python":
            text, notes = py_syntax_fix_round(text)
            log += notes
            if not notes:
                text, notes = py_semantic_fix_round(text)
                log += notes
        elif lang_id in ("c", "cpp") and linter_tool(lang_id):
            edits, notes = clang_fix_edits(lang_id, text)
            if edits:
                fixed = apply_text_edits(text, edits)
                if fixed != text:
                    text = fixed
                    log += [n + "  -> applied the compiler's fix"
                            for n in notes[:len(edits)]]
        elif lang_id == "go":
            text, notes = go_structure_fix(text)
            log += notes
            if not notes and linter_tool(lang_id):
                text, notes = external_fix_round(lang_id, text)
                log += notes
        elif linter_tool(lang_id):
            text, notes = external_fix_round(lang_id, text)
            log += notes

        if text == start:
            break

    if want_layout:
        if lang_id == "python":
            t2 = strip_trailing_ws(reindent_python(text), lang_id)
        elif lang_id == "html":
            t2 = strip_trailing_ws(reindent_html(text), lang_id)
        elif lang_id in BRACE_LANGS and lang_id != "json":
            t2 = strip_trailing_ws(reindent_braces(text, lang_id), lang_id)
        else:
            t2 = strip_trailing_ws(text, lang_id)
        if t2 != text:
            log.append("normalized indentation and whitespace")
            text = t2

    # What is left? Prefer the real checker's verdict when one exists.
    try:
        remaining = check_source(text, lang_id,
                                 heuristics=linter_tool(lang_id) is None)
    except Exception:
        remaining = []
    if linter_tool(lang_id):
        try:
            remaining = [Issue(l, c, c + 1, sev, msg, fix)
                         for (l, c, sev, msg, fix) in run_linter(lang_id, text)]
        except Exception:
            pass
    return text, log, remaining


# --------------------------------------------------------------------------
# Completion engine (document words + language vocabulary, ranked).
# --------------------------------------------------------------------------

WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def collect_completions(text, prefix, lang_id, limit=12):
    if not prefix:
        return []
    sp = LANGS[lang_id]
    words = Counter(WORD_RE.findall(text))
    if prefix in words:
        words[prefix] -= 1
    cands = {}
    for w, cnt in words.items():
        if len(w) >= 2 and cnt > 0:
            cands[w] = cnt
    for pool, bonus in ((sp["keywords"], 3), (sp["builtins"], 2),
                        (sp["types"], 2), (sp["constants"], 2)):
        for w in pool:
            cands[w] = cands.get(w, 0) + bonus
    lp = prefix.lower()
    exact, loose = [], []
    for w, cnt in cands.items():
        if w == prefix:
            continue
        if w.startswith(prefix):
            exact.append((-cnt, len(w), w))
        elif w.lower().startswith(lp):
            loose.append((-cnt, len(w), w))
    exact.sort()
    loose.sort()
    return [w for _, _, w in exact + loose][:limit]


def current_word(line_to_cursor):
    m = re.search(r"[A-Za-z_][A-Za-z0-9_]*$", line_to_cursor)
    return m.group(0) if m else ""


# Standard-library modules that are safe to import for introspection-based
# member completion (import has no side effects). All offline.
_SAFE_STDLIB = {
    "os", "sys", "re", "math", "cmath", "random", "json", "time", "datetime",
    "collections", "itertools", "functools", "operator", "string", "textwrap",
    "statistics", "decimal", "fractions", "pathlib", "glob", "shutil",
    "tempfile", "io", "csv", "sqlite3", "hashlib", "hmac", "secrets", "base64",
    "struct", "array", "bisect", "heapq", "copy", "pprint", "enum", "types",
    "typing", "dataclasses", "abc", "numbers", "unicodedata", "difflib",
    "urllib", "http", "socket", "threading", "multiprocessing", "queue",
    "subprocess", "signal", "select", "asyncio", "logging", "argparse",
    "configparser", "platform", "getpass", "uuid", "zlib", "gzip", "bz2",
    "lzma", "zipfile", "tarfile", "pickle", "shelve", "calendar", "locale",
    "gettext", "warnings", "traceback", "inspect", "importlib", "contextlib",
    "weakref", "gc", "ast", "dis", "tokenize", "keyword", "builtins",
    "turtle", "tkinter", "html", "xml", "email", "unittest", "doctest",
    "timeit", "cProfile", "profile", "webbrowser", "ctypes", "fnmatch",
}
_member_cache = {}


def python_member_completions(text, obj, prefix, limit=40):
    """Complete `obj.<prefix>` when obj is an imported stdlib module.
    Uses dir() introspection - entirely offline, no code execution."""
    real = None
    for m in re.finditer(r"^[ \t]*import[ \t]+(.+)$", text, re.M):
        for part in m.group(1).split(","):
            p = part.strip().split("#")[0].strip()
            mm = re.match(r"([\w.]+)(?:[ \t]+as[ \t]+(\w+))?$", p)
            if not mm:
                continue
            alias = mm.group(2) or mm.group(1).split(".")[0]
            if alias == obj:
                real = mm.group(1) if mm.group(2) else mm.group(1).split(".")[0]
    if real is None and obj in _SAFE_STDLIB:
        real = obj
    if real is None or real.split(".")[0] not in _SAFE_STDLIB:
        return None
    if real not in _member_cache:
        try:
            import importlib
            mod = importlib.import_module(real)
            names = [n for n in dir(mod) if not n.startswith("__")]
            _member_cache[real] = sorted(names)
        except Exception:
            _member_cache[real] = []
    members = _member_cache[real]
    lp = prefix.lower()
    hits = [n for n in members if n.startswith(prefix)]
    if not hits:
        hits = [n for n in members if n.lower().startswith(lp)]
    pub = [n for n in hits if not n.startswith("_")]
    return (pub + [n for n in hits if n.startswith("_")])[:limit] or None


# Literal-based type inference for `variable.` completion (offline dir()).
_PY_TYPE_OF_LITERAL = (
    (re.compile(r"""=\s*(?:[frbuFRBU]{0,2})(?:\"|')"""), "str"),
    (re.compile(r"=\s*\["), "list"),
    (re.compile(r"=\s*\{\s*\}"), "dict"),
    (re.compile(r"=\s*\{[^}\n]*:"), "dict"),
    (re.compile(r"=\s*\{"), "set"),
    (re.compile(r"=\s*\("), "tuple"),
    (re.compile(r"=\s*-?\d+\.\d*"), "float"),
    (re.compile(r"=\s*-?\d"), "int"),
    (re.compile(r"=\s*(?:True|False)\b"), "bool"),
)
_PY_TYPE_OBJ = {"str": str, "list": list, "dict": dict, "set": set,
                "tuple": tuple, "int": int, "float": float, "bool": bool}
_TYPE_MEMBER_CACHE = {}


def py_var_type(text, name):
    """Best-effort type of a variable from its literal assignments."""
    ty = None
    for m in re.finditer(r"(?m)^[ \t]*%s[ \t]*(=[^=].*)$" % re.escape(name),
                         text):
        rhs = m.group(1)
        for rx, t in _PY_TYPE_OF_LITERAL:
            if rx.match(rhs):
                ty = t
                break
    return ty


def py_type_members(ty, prefix):
    if ty not in _TYPE_MEMBER_CACHE:
        _TYPE_MEMBER_CACHE[ty] = sorted(
            n for n in dir(_PY_TYPE_OBJ[ty]) if not n.startswith("_"))
    hits = [n for n in _TYPE_MEMBER_CACHE[ty] if n.startswith(prefix)]
    return hits[:24] or None


def compute_completions(text, line_before_cursor, lang_id):
    """Candidate FULL replacements for the token before the caret.
    After a dot: module members / inferred-type methods / self attributes /
    identifiers-seen-after-dots. Otherwise ranked word completion."""
    prefix = current_word(line_before_cursor)
    m = re.search(r"([A-Za-z_][\w]*)\.%s$" % re.escape(prefix),
                  line_before_cursor)
    str_dot = re.search(r"""["']\s*\.%s$""" % re.escape(prefix),
                        line_before_cursor)
    if m or str_dot:
        if lang_id == "python":
            if str_dot:
                got = py_type_members("str", prefix)
                if got:
                    return got
            else:
                obj = m.group(1)
                got = python_member_completions(text, obj, prefix)
                if got:
                    return got
                if obj == "self":
                    attrs = sorted(set(re.findall(r"\bself\.(\w+)", text)))
                    hits = [a for a in attrs
                            if a.startswith(prefix) and a != prefix]
                    if hits:
                        return hits[:24]
                ty = py_var_type(text, obj)
                if ty:
                    got = py_type_members(ty, prefix)
                    if got:
                        return got
        # Any language: identifiers this document uses after a dot.
        dots = Counter(re.findall(r"\.([A-Za-z_]\w+)", text))
        if prefix in dots:
            dots[prefix] -= 1
        hits = [(n, w) for w, n in dots.items()
                if w.startswith(prefix) and n > 0 and w != prefix]
        hits.sort(key=lambda t: (-t[0], len(t[1]), t[1]))
        if hits:
            return [w for _, w in hits][:16]
    return collect_completions(text, prefix, lang_id)


# --------------------------------------------------------------------------
# Running & debugging - entirely with tools already on this computer.
# --------------------------------------------------------------------------

def which_tool(*names):
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    return None


def _tool_missing(name, hint):
    return ("info",
            "%s is not installed on this computer. %s\n"
            "GeskoIDE runs code with local tools only (no internet needed "
            "while coding)." % (name, hint))


# Executes a .sql file against an in-memory SQLite database using nothing
# but the Python standard library, printing SELECT results as tables.
SQL_RUNNER_SRC = r'''
import sqlite3, sys
db = sqlite3.connect(":memory:")
cur = db.cursor()
buf = ""
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    src = f.read()
for line in src.splitlines(True):
    buf += line
    if sqlite3.complete_statement(buf):
        stmt = buf.strip()
        buf = ""
        if not stmt:
            continue
        try:
            cur.execute(stmt)
        except sqlite3.Error as e:
            print("SQL error: %s" % e)
            print("  in: %s" % stmt.splitlines()[0][:70])
            continue
        if cur.description:
            cols = [d[0] for d in cur.description]
            rows = cur.fetchmany(200)
            widths = [max(len(str(c)), *(len(str(r[i])) for r in rows))
                      if rows else len(str(c)) for i, c in enumerate(cols)]
            line1 = " | ".join(str(c).ljust(widths[i])
                               for i, c in enumerate(cols))
            print(line1)
            print("-+-".join("-" * w for w in widths))
            for r in rows:
                print(" | ".join(str(v).ljust(widths[i])
                                 for i, v in enumerate(r)))
            print("(%d row%s)" % (len(rows), "" if len(rows) == 1 else "s"))
        elif cur.rowcount != -1:
            print("ok (%d row%s affected)"
                  % (cur.rowcount, "" if cur.rowcount == 1 else "s"))
if buf.strip():
    try:
        cur.execute(buf)
        print("ok")
    except sqlite3.Error as e:
        print("SQL error: %s" % e)
db.commit()
'''


def _native_debugger():
    """Path to lldb or gdb if present (both ship with common dev toolchains)."""
    return which_tool("lldb", "gdb")


def _dbg_step(dbg, binout):
    """A step that drops into lldb/gdb at the program's start, interactively."""
    if dbg.endswith("lldb"):
        return {"argv": [dbg, binout],
                "label": "lldb - type:  b main | run | n | s | p <var> | c | q"}
    return {"argv": [dbg, binout],
            "label": "gdb - type:  break main | run | next | step | print <v> "
                     "| continue | quit"}


def build_steps(lang_id, path, debug=False, breakpoints=()):
    """Return ("steps", [ {argv, label?, stdin_file?} ]) or ("info", msg)
    or ("open", path). Everything runs 100% locally."""
    r = LANGS[lang_id]["run"] or lang_id
    stem = os.path.splitext(os.path.basename(path))[0]
    tmpdir = tempfile.mkdtemp(prefix="geskoide-run-")
    binout = os.path.join(tmpdir, stem + (".exe" if IS_WIN else ".bin"))

    if r == "python":
        py = sys.executable or which_tool("python3", "python")
        if debug:
            argv = [py, "-u", "-m", "pdb"]
            for bp in sorted(breakpoints or ()):
                argv += ["-c", "b %d" % bp]
            if breakpoints:
                argv += ["-c", "c"]
            argv.append(path)
            lbl = ("pdb debugger%s - use the buttons above, or type: n=next  "
                   "s=step  c=continue  p expr  q=quit"
                   % (" · %d breakpoint%s set"
                      % (len(breakpoints), "" if len(breakpoints) == 1
                         else "s") if breakpoints else ""))
            return "steps", [{"argv": argv, "label": lbl}]
        return "steps", [{"argv": [py, "-u", path]}]

    if r == "node":
        node = which_tool("node")
        if not node:
            return _tool_missing("Node.js", "Install it once from nodejs.org "
                                            "(or: brew install node).")
        if debug:
            return "steps", [{"argv": [node, "inspect", path],
                              "label": "node inspect - type:  cont | next | "
                                       "step | out | repl | exec <expr> | .exit"}]
        return "steps", [{"argv": [node, path]}]

    if r == "typescript":
        deno = which_tool("deno")
        if deno:
            return "steps", [{"argv": [deno, "run", "--allow-all", path]}]
        bun = which_tool("bun")
        if bun:
            return "steps", [{"argv": [bun, "run", path]}]
        tsn = which_tool("ts-node")
        if tsn:
            return "steps", [{"argv": [tsn, path]}]
        return _tool_missing("A TypeScript runtime (Deno, Bun or ts-node)",
                             "Plain JavaScript runs with Node out of the box.")

    if r == "shell":
        sh = which_tool("bash", "zsh", "sh")
        if not sh:
            return _tool_missing("A POSIX shell", "")
        argv = [sh, "-x", path] if debug else [sh, path]
        lbl = "bash -x trace" if debug else None
        step = {"argv": argv}
        if lbl:
            step["label"] = lbl
        return "steps", [step]

    if r in ("ruby", "perl", "php", "lua"):
        t = which_tool(r)
        if not t:
            return _tool_missing(LANGS[lang_id]["name"],
                                 "macOS ships Ruby and Perl; PHP/Lua: brew install %s." % r)
        if debug and r == "perl":
            return "steps", [{"argv": [t, "-d", path],
                              "label": "perl debugger - type:  n | s | c | "
                                       "p $var | b <line> | q"}]
        if debug and r == "ruby":
            rdbg = which_tool("rdbg")
            if rdbg:
                return "steps", [{"argv": [rdbg, path],
                                  "label": "rdbg - type:  step | next | "
                                           "continue | p <expr> | break <line>"}]
        return "steps", [{"argv": [t, path]}]

    if r == "applescript":
        osa = which_tool("osascript")
        if not osa:
            return "info", "AppleScript needs macOS (osascript was not found)."
        return "steps", [{"argv": [osa, path]}]

    if r == "swift":
        sw = which_tool("swift")
        if not sw:
            return _tool_missing("Swift", "Run once:  xcode-select --install")
        return "steps", [{"argv": [sw, path]}]

    if r == "c":
        cc = which_tool("cc", "clang", "gcc")
        if not cc:
            return _tool_missing("A C compiler", "Run once:  xcode-select --install")
        base = [cc, "-std=c11", "-Wall"]
        tail = (["-lm"] if not IS_WIN else [])
        dbg = _native_debugger()
        if debug and dbg:
            return "steps", [{"argv": base + ["-g", "-O0", path, "-o", binout]
                              + tail, "label": "compile (with debug info)"},
                             _dbg_step(dbg, binout)]
        return "steps", [{"argv": base + [path, "-o", binout] + tail,
                          "label": "compile"},
                         {"argv": [binout], "label": "run"}]

    if r == "cpp":
        cxx = which_tool("c++", "clang++", "g++")
        if not cxx:
            return _tool_missing("A C++ compiler", "Run once:  xcode-select --install")
        base = [cxx, "-std=c++17", "-Wall"]
        dbg = _native_debugger()
        if debug and dbg:
            return "steps", [{"argv": base + ["-g", "-O0", path, "-o", binout],
                              "label": "compile (with debug info)"},
                             _dbg_step(dbg, binout)]
        return "steps", [{"argv": base + [path, "-o", binout],
                          "label": "compile"},
                         {"argv": [binout], "label": "run"}]

    if r == "go":
        g = which_tool("go")
        if not g:
            return _tool_missing(
                "Go", "Install once from go.dev (or: brew install go). "
                "The Android APK bundles its own Go runner; this Mac .command "
                "file stays a single Python app and uses the tools installed "
                "on this computer.")
        if debug:
            dlv = which_tool("dlv")
            if dlv:
                return "steps", [{"argv": [dlv, "debug", path],
                                  "label": "delve - type:  break main.main | "
                                           "continue | next | step | print <v> "
                                           "| quit"}]
            return "steps", [{"argv": [g, "run", path],
                              "label": "run (install 'dlv' for step debugging: "
                                       "go install github.com/go-delve/delve/"
                                       "cmd/dlv@latest)"}]
        return "steps", [{"argv": [g, "run", path]}]

    if r == "rust":
        rc_ = which_tool("rustc")
        if not rc_:
            return _tool_missing("Rust", "Install once from rustup.rs.")
        dbg = which_tool("rust-lldb", "rust-gdb") or _native_debugger()
        if debug and dbg:
            return "steps", [{"argv": [rc_, "-g", path, "-o", binout],
                              "label": "compile (with debug info)"},
                             _dbg_step(dbg, binout)]
        return "steps", [{"argv": [rc_, path, "-o", binout], "label": "compile"},
                         {"argv": [binout], "label": "run"}]

    if r == "java":
        j = which_tool("java")
        if not j:
            return _tool_missing("Java (JDK 11+)", "Install once: brew install openjdk.")
        if debug and which_tool("jdb"):
            return "steps", [{"argv": [which_tool("jdb"), path],
                              "label": "jdb - type:  stop at Main:<line> | run "
                                       "| next | step | print <v> | cont"}]
        return "steps", [{"argv": [j, path]}]

    if r == "kotlin":
        k = which_tool("kotlinc")
        if not k:
            return _tool_missing("Kotlin", "Install once: brew install kotlin.")
        jar = os.path.join(tmpdir, stem + ".jar")
        return "steps", [{"argv": [k, path, "-include-runtime", "-d", jar],
                          "label": "compile"},
                         {"argv": [which_tool("java") or "java", "-jar", jar],
                          "label": "run"}]

    if r == "csharp":
        d = which_tool("dotnet")
        if not d:
            return _tool_missing("The .NET SDK", "Install once: brew install dotnet-sdk.")
        return "info", ("C# needs a project to run: in Terminal, "
                        "`dotnet new console` once, then GeskoIDE can edit the "
                        "files and you run with `dotnet run`.")

    if r == "sql":
        # SQLite ships INSIDE Python's standard library - no external tool,
        # no install, works offline everywhere GeskoIDE runs.
        py = sys.executable or which_tool("python3", "python")
        return "steps", [{"argv": [py, "-c", SQL_RUNNER_SRC, path],
                          "label": "SQLite (bundled with GeskoIDE)"}]

    if r == "html":
        return "open", path

    if r in ("css", "yaml", "text"):
        return "info", ("A %s file has nothing to execute. Use Run on a "
                        "program file, or open an HTML page for preview."
                        % LANGS[lang_id]["name"])

    return "info", "GeskoIDE does not know how to run %s yet." % LANGS[lang_id]["name"]


def markdown_to_html(md, title="Preview"):
    """Deliberately small offline Markdown-to-HTML converter for previews."""
    def esc(s):
        return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

    out = []
    in_code = False
    in_list = False
    for line in md.split("\n"):
        if line.strip().startswith("```"):
            out.append("</pre>" if in_code else "<pre>")
            in_code = not in_code
            continue
        if in_code:
            out.append(esc(line))
            continue
        t = esc(line)
        t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
        t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
        t = re.sub(r"\*([^*]+)\*", r"<i>\1</i>", t)
        t = re.sub(r"\[([^\]]*)\]\(([^)]*)\)", r'<a href="\2">\1</a>', t)
        m = re.match(r"^(#{1,6})\s*(.*)$", t)
        if m:
            if in_list:
                out.append("</ul>")
                in_list = False
            n = len(m.group(1))
            out.append("<h%d>%s</h%d>" % (n, m.group(2), n))
            continue
        m = re.match(r"^\s*[-*+]\s+(.*)$", t)
        if m:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>%s</li>" % m.group(1))
            continue
        if in_list and not line.strip():
            out.append("</ul>")
            in_list = False
            continue
        out.append(t + "<br>" if line.strip() else "")
    if in_list:
        out.append("</ul>")
    if in_code:
        out.append("</pre>")
    return ("<!DOCTYPE html><html><head><meta charset='utf-8'><title>%s</title>"
            "<style>body{font-family:-apple-system,'Helvetica Neue',sans-serif;"
            "max-width:46em;margin:2em auto;padding:0 1em;line-height:1.55;"
            "color:#1c2622}pre,code{background:#eef4f0;border-radius:5px;"
            "padding:2px 5px}pre{padding:12px;overflow:auto}"
            "a{color:#1d8a5b}</style></head><body>%s</body></html>"
            % (esc(title), "\n".join(out)))


class StepRunner:
    """Runs subprocess steps in sequence; streams events through a queue.
    Events: ("cmd"|"out"|"err"|"info", text) and finally ("done", rc, secs)."""

    def __init__(self, steps, cwd=None):
        self.steps = steps
        self.cwd = cwd
        self.events = _queue.Queue()
        self.proc = None
        self._stop = False
        self.thread = threading.Thread(target=self._work, daemon=True)

    def start(self):
        self.thread.start()

    def alive(self):
        return self.thread.is_alive()

    def send_line(self, line):
        p = self.proc
        try:
            if p and p.poll() is None and p.stdin:
                p.stdin.write(line + "\n")
                p.stdin.flush()
        except OSError:
            pass

    def stop(self):
        self._stop = True
        p = self.proc
        if p and p.poll() is None:
            try:
                p.terminate()
            except OSError:
                pass

            def _kill():
                time.sleep(1.2)
                if p.poll() is None:
                    try:
                        p.kill()
                    except OSError:
                        pass
            threading.Thread(target=_kill, daemon=True).start()

    def _reader(self, stream, tag):
        try:
            for line in iter(stream.readline, ""):
                self.events.put((tag, line))
        except Exception:
            pass
        finally:
            try:
                stream.close()
            except Exception:
                pass

    def _work(self):
        t0 = time.time()
        rc = 0
        env = dict(os.environ)
        env["PYTHONUNBUFFERED"] = "1"
        for step in self.steps:
            if self._stop:
                break
            argv = step["argv"]
            if step.get("label"):
                self.events.put(("info", "[%s]\n" % step["label"]))
            self.events.put(("cmd", "$ %s\n" % " ".join(argv)))
            fin = subprocess.PIPE
            stdin_file = step.get("stdin_file")
            try:
                if stdin_file:
                    fin = open(stdin_file, "r", encoding="utf-8")
                self.proc = subprocess.Popen(
                    argv, cwd=self.cwd, env=env, stdin=fin,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, bufsize=1, encoding="utf-8", errors="replace")
            except OSError as ex:
                self.events.put(("err", "Could not start %s: %s\n" % (argv[0], ex)))
                rc = 127
                break
            readers = [
                threading.Thread(target=self._reader,
                                 args=(self.proc.stdout, "out"), daemon=True),
                threading.Thread(target=self._reader,
                                 args=(self.proc.stderr, "err"), daemon=True)]
            for rd in readers:
                rd.start()
            rc = self.proc.wait()
            for rd in readers:
                rd.join(timeout=2)
            if stdin_file and fin is not subprocess.PIPE:
                try:
                    fin.close()
                except Exception:
                    pass
            if rc != 0:
                break
        self.events.put(("done", rc, time.time() - t0))


# --------------------------------------------------------------------------
# GUI (tkinter). Guarded so --selftest works even without a display / Tk.
# --------------------------------------------------------------------------

try:
    import tkinter as tk
    from tkinter import filedialog, messagebox
    from tkinter import font as tkfont
    TK_OK = True
except Exception:                                       # pragma: no cover
    tk = None
    TK_OK = False

ALL_TOKEN_TAGS = list(TOKEN_COLORS.keys())
ISSUE_TAGS = ("iss_error", "iss_warn", "iss_info")
SEV_COLOR_KEY = {"error": "error", "warn": "warn", "info": "info"}

if TK_OK:

    def pick_family(root, prefs, fallback):
        try:
            fams = set(tkfont.families(root))
        except Exception:
            return fallback
        for f in prefs:
            if f in fams:
                return f
        return fallback

    class FlatButton(tk.Label):
        """A theme-friendly button (tk.Button ignores colors on macOS Aqua)."""

        def __init__(self, master, text, command=None, kind="ghost",
                     padx=12, pady=5, font=None):
            self.command = command
            if kind == "primary":
                cfg = ("#2a9463", "#eafff2", "#3fd68f", "#07130d")
            elif kind == "danger":
                cfg = ("#54222c", "#ffd7d7", "#7c3140", "#ffe3e3")
            else:
                cfg = (THEME["bg_panel"], THEME["fg"],
                       THEME["bg_hover"], THEME["fg"])
            self.c_bg, self.c_fg, self.c_hbg, self.c_hfg = cfg
            super().__init__(master, text=text, bg=self.c_bg, fg=self.c_fg,
                             padx=padx, pady=pady, cursor="hand2",
                             font=font)
            self.bind("<Enter>", lambda e: self.configure(bg=self.c_hbg,
                                                          fg=self.c_hfg))
            self.bind("<Leave>", lambda e: self.configure(bg=self.c_bg,
                                                          fg=self.c_fg))
            self.bind("<Button-1>", self._click)

        def _click(self, ev=None):
            if self.command:
                self.command()

    class Popup(tk.Toplevel):
        def __init__(self, master):
            super().__init__(master)
            self.overrideredirect(True)
            try:
                self.attributes("-topmost", True)
            except tk.TclError:
                pass
            self.configure(bg=THEME["border"])

    class CompletionPopup(Popup):
        def __init__(self, master, app, words, on_accept):
            super().__init__(master)
            self.on_accept = on_accept
            self.lb = tk.Listbox(self, bg=THEME["bg_panel"], fg=THEME["fg"],
                                 selectbackground=THEME["accent_dark"],
                                 selectforeground="#eafff2",
                                 highlightthickness=0, bd=0,
                                 activestyle="none", font=app.mono_font,
                                 width=0, height=min(8, len(words)))
            self.lb.pack(padx=1, pady=1)
            self.fill(words)
            self.lb.bind("<Double-Button-1>", lambda e: self.accept())

        def fill(self, words):
            self.lb.delete(0, "end")
            for w in words:
                self.lb.insert("end", " %s " % w)
            self.lb.configure(height=min(8, max(1, len(words))))
            self.lb.selection_clear(0, "end")
            self.lb.selection_set(0)
            self.lb.activate(0)

        def move(self, d):
            cur = self.lb.curselection()
            i = max(0, min(self.lb.size() - 1, (cur[0] if cur else 0) + d))
            self.lb.selection_clear(0, "end")
            self.lb.selection_set(i)
            self.lb.activate(i)
            self.lb.see(i)

        def accept(self):
            cur = self.lb.curselection()
            if cur:
                self.on_accept(self.lb.get(cur[0]).strip())

    class HintPopup(Popup):
        """The automatic hint bubble that appears while you type."""

        def __init__(self, master, app, issue, on_fix):
            super().__init__(master)
            row = tk.Frame(self, bg=THEME["bg_panel"])
            row.pack(padx=1, pady=1)
            tk.Label(row, text="●", fg=THEME[SEV_COLOR_KEY[issue.severity]],
                     bg=THEME["bg_panel"], font=app.small_font)\
                .pack(side="left", padx=(9, 4), pady=4)
            msg = issue.msg + ("   -  press Tab to fix" if issue.fix else "")
            tk.Label(row, text=msg, fg=THEME["fg"], bg=THEME["bg_panel"],
                     font=app.small_font).pack(side="left", pady=4)
            if issue.fix and on_fix:
                FlatButton(row, "Fix", command=on_fix, kind="primary",
                           padx=9, pady=1, font=app.small_font)\
                    .pack(side="left", padx=9, pady=3)
            else:
                tk.Label(row, text="  ", bg=THEME["bg_panel"]).pack(side="left")

    class LineNumbers(tk.Canvas):
        def __init__(self, master, editor):
            super().__init__(master, width=52, bg=THEME["bg_gutter"],
                             highlightthickness=0, bd=0)
            self.editor = editor
            self._job = None
            self.bind("<Button-1>", self._click)

        def schedule(self):
            if self._job is None:
                self._job = self.after(15, self.redraw)

        def redraw(self):
            self._job = None
            ed = self.editor
            t = ed.text
            self.delete("all")
            try:
                cur = int(t.index("insert").split(".")[0])
            except tk.TclError:
                return
            fnt = ed.app.mono_font
            w = self.winfo_width()
            i = t.index("@0,0")
            for _ in range(400):
                d = t.dlineinfo(i)
                if d is None:
                    break
                ln = int(i.split(".")[0])
                y = d[1]
                color = THEME["accent"] if ln == cur else THEME["fg_faint"]
                self.create_text(w - 8, y + 1, anchor="ne", text=str(ln),
                                 fill=color, font=fnt)
                if ln in ed.breakpoints:
                    self.create_oval(2, y + 3, 13, y + 14, outline="",
                                     fill="#e05555")
                sev = ed.issue_lines.get(ln)
                if sev:
                    x0 = 15 if ln in ed.breakpoints else 5
                    self.create_oval(x0, y + 5, x0 + 6, y + 11, outline="",
                                     fill=THEME[SEV_COLOR_KEY[sev]])
                nxt = t.index("%d.0+1line" % ln)
                if nxt == i:
                    break
                i = nxt
            digits = len(t.index("end-1c").split(".")[0])
            want = 24 + fnt.measure("0") * max(2, digits)
            if abs(want - w) > 3:
                self.configure(width=want)

        def _click(self, ev):
            i = self.editor.text.index("@0,%d" % ev.y)
            ln = int(i.split(".")[0])
            if ev.x <= 14:
                # click the left edge: toggle a breakpoint (used by Debug)
                self.editor.toggle_breakpoint(ln)
                return
            self.editor.text.mark_set("insert", "%s linestart" % i)
            self.editor.text.focus_set()
            self.editor.update_current_line()
            self.schedule()

    class EditorTab(tk.Frame):
        """One open file: gutter + text + highlighting + auto-check."""

        _counter = [0]
        _mark_seq = [0]

        def __init__(self, master, app, path=None, lang=None, content="",
                     placeholders=()):
            super().__init__(master, bg=THEME["bg_editor"])
            self.app = app
            self.path = path
            first = content.split("\n", 1)[0] if content else ""
            self.lang = lang or detect_language(path, first)
            if path:
                self.title = os.path.basename(path)
            else:
                EditorTab._counter[0] += 1
                exts = LANGS[self.lang]["exts"]
                self.title = "Untitled-%d%s" % (EditorTab._counter[0],
                                                exts[0] if exts else ".txt")
            self.dirty = False
            self.issues = []
            self.issue_lines = {}
            self.check_error = None
            self.placeholder_marks = []
            self._jobs = {}
            self._suppress = False
            self._version = 0            # bumps on every edit (lint staleness)
            self._comp = None            # inline completion cycle state
            self.breakpoints = set()     # 1-based line numbers (click gutter)
            self._lint_q = _queue.Queue()
            self._lint_running = False
            self._lint_pending = False
            self._lint_show_hint = False

            self.gutter = LineNumbers(self, self)
            self.gutter.pack(side="left", fill="y")
            body = tk.Frame(self, bg=THEME["bg_editor"])
            body.pack(side="left", fill="both", expand=True)
            body.rowconfigure(0, weight=1)
            body.columnconfigure(0, weight=1)

            self.text = tk.Text(
                body, wrap="none", undo=True, autoseparators=True, maxundo=-1,
                bd=0, highlightthickness=0, bg=THEME["bg_editor"],
                fg=TOKEN_COLORS["ident"], insertbackground=THEME["caret"],
                insertwidth=2, selectbackground=THEME["sel"],
                selectforeground=THEME["fg"], padx=10, pady=8,
                font=app.mono_font, spacing1=1, spacing3=1)
            self.vsb = tk.Scrollbar(body, orient="vertical",
                                    command=self.text.yview, width=16)
            hsb = tk.Scrollbar(body, orient="horizontal", command=self.text.xview)
            self._vscroll_visible = True
            self._vscroll_dragging = False
            self.text.grid(row=0, column=0, sticky="nsew")
            self.vsb.grid(row=0, column=1, sticky="ns")
            hsb.grid(row=1, column=0, sticky="ew")

            def _yset(a, b):
                self.vsb.set(a, b)
                self.gutter.schedule()
                if len(self.get_text()) > 200000:
                    self._schedule("hl_view", 200, self.highlight_viewport)
            self.text.configure(yscrollcommand=_yset, xscrollcommand=hsb.set)
            self._hide_vscroll()
            self.apply_font()

            self._config_tags()
            if content:
                self.text.insert("1.0", content)
            for s, e in placeholders:
                self._add_placeholder("1.0+%dc" % s, "1.0+%dc" % e)
            self.text.edit_reset()
            self.text.edit_modified(False)
            self._bind()
            self.highlight_all()
            self.run_checks(show_hint=False)
            self.update_current_line()
            if self.placeholder_marks:
                self.after(60, self.jump_placeholder)

        # ---- setup -------------------------------------------------------

        def _config_tags(self):
            t = self.text
            t.tag_configure("current_line", background=THEME["current_line"])
            for name, color in TOKEN_COLORS.items():
                kw = {"foreground": color}
                if name in TOKEN_BOLD:
                    kw["font"] = self.app.mono_bold
                elif name in TOKEN_ITALIC:
                    kw["font"] = self.app.mono_italic
                t.tag_configure(name, **kw)
            t.tag_configure("iss_error", underline=True, background="#331a1e")
            t.tag_configure("iss_warn", underline=True, background="#33290f")
            t.tag_configure("iss_info", underline=True)
            t.tag_configure("find_match", background=THEME["find_match"])
            t.tag_configure("brk_match", background=THEME["brk_match"])
            t.tag_raise("sel")

        def _bind(self):
            t = self.text
            t.bind("<<Modified>>", self._on_modified)
            t.bind("<KeyRelease>", self._on_key_release)
            t.bind("<ButtonRelease-1>", self._on_click)
            t.bind("<KeyPress-Tab>", self._key_tab)
            for seq in ("<Shift-Tab>", "<ISO_Left_Tab>", "<Shift-ISO_Left_Tab>"):
                try:
                    t.bind(seq, self._key_shift_tab)
                except tk.TclError:
                    pass
            t.bind("<KeyPress-Return>", self._key_return)
            t.bind("<KeyPress-KP_Enter>", self._key_return)
            t.bind("<KeyPress-BackSpace>", self._key_backspace)
            t.bind("<KeyPress-Escape>", self._key_escape)
            t.bind("<KeyPress-Up>", lambda e: self._key_updown(-1))
            t.bind("<KeyPress-Down>", lambda e: self._key_updown(1))
            t.bind("<KeyPress-parenleft>", lambda e: self._key_open(e, "(", ")"))
            t.bind("<KeyPress-bracketleft>", lambda e: self._key_open(e, "[", "]"))
            t.bind("<KeyPress-braceleft>", lambda e: self._key_open(e, "{", "}"))
            t.bind("<KeyPress-parenright>", lambda e: self._key_close(e, ")"))
            t.bind("<KeyPress-bracketright>", lambda e: self._key_close(e, "]"))
            t.bind("<KeyPress-braceright>", lambda e: self._key_close(e, "}"))
            t.bind("<KeyPress-quotedbl>", lambda e: self._key_quote(e, '"'))
            t.bind("<KeyPress-apostrophe>", lambda e: self._key_quote(e, "'"))
            t.bind("<KeyPress-grave>", lambda e: self._key_quote(e, "`"))
            t.bind("<Motion>", self._edge_scroll_motion)
            t.bind("<Leave>", lambda e: self._hide_vscroll_later())
            self.vsb.bind("<Enter>", lambda e: self._show_vscroll())
            self.vsb.bind("<Leave>", lambda e: self._hide_vscroll_later())
            self.vsb.bind("<ButtonPress-1>", self._vscroll_press)
            self.vsb.bind("<ButtonRelease-1>", self._vscroll_release)

        def apply_font(self):
            sp = LANGS[self.lang]
            px = max(8, self.app.mono_font.measure("0") * sp["indent"])
            self.text.configure(font=self.app.mono_font, tabs=(px,))

        def _show_vscroll(self):
            if not self._vscroll_visible:
                self.vsb.grid(row=0, column=1, sticky="ns")
                self._vscroll_visible = True

        def _hide_vscroll(self):
            if self._vscroll_visible and not self._vscroll_dragging:
                self.vsb.grid_remove()
                self._vscroll_visible = False

        def _hide_vscroll_later(self):
            self._schedule("hide_vscroll", 650, self._hide_vscroll)

        def _edge_scroll_motion(self, ev):
            if ev.x >= max(0, self.text.winfo_width() - 28):
                self._show_vscroll()
            elif self._vscroll_visible and not self._vscroll_dragging:
                self._hide_vscroll_later()

        def _vscroll_press(self, ev):
            self._vscroll_dragging = True
            self._show_vscroll()

        def _vscroll_release(self, ev):
            self._vscroll_dragging = False
            self._hide_vscroll_later()

        # ---- small helpers -------------------------------------------------

        def get_text(self):
            return self.text.get("1.0", "end-1c")

        def _schedule(self, key, ms, fn):
            old = self._jobs.pop(key, None)
            if old is not None:
                try:
                    self.after_cancel(old)
                except Exception:
                    pass

            def run():
                self._jobs.pop(key, None)
                fn()
            self._jobs[key] = self.after(ms, run)

        def cur_line(self):
            return int(self.text.index("insert").split(".")[0])

        def update_current_line(self):
            t = self.text
            t.tag_remove("current_line", "1.0", "end")
            t.tag_add("current_line", "insert linestart", "insert lineend+1c")

        # ---- events --------------------------------------------------------

        # Keys that never change the text; they must not mark the file dirty
        # or trigger a re-check on their own.
        _NON_EDIT_KEYS = frozenset((
            "Left", "Right", "Up", "Down", "Home", "End", "Prior", "Next",
            "Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R",
            "Meta_L", "Meta_R", "Super_L", "Super_R", "Command_L", "Command_R",
            "Caps_Lock", "Num_Lock", "Escape", "Menu", "Help",
            "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
            "F11", "F12"))

        def _mark_dirty(self):
            if not self.dirty:
                self.dirty = True
                self.app.refresh_titles()

        def _schedule_updates(self):
            self._version += 1
            self._schedule("hl_line", 50, self.highlight_line_now)
            self._schedule("hl_full", 400, self.highlight_all)
            self._schedule("check", 550, self.run_checks)
            if getattr(self.app, "outline", None) and self.app.outline.visible:
                self._schedule("outline", 750, self.app.refresh_outline_if_visible)

        def _on_modified(self, ev=None):
            if self._suppress:
                return
            self._suppress = True
            try:
                self.text.edit_modified(False)
            finally:
                self._suppress = False
            self._mark_dirty()
            self._schedule_updates()

        def _on_key_release(self, ev=None):
            app = self.app
            self.update_current_line()
            self.gutter.schedule()
            app.update_status()
            self._match_brackets()
            # Belt-and-suspenders: the <<Modified>> virtual event is delivered
            # unreliably on some Tk builds (notably macOS Aqua), so also drive
            # highlighting and auto-check straight from real key releases
            # whenever the keystroke could have changed the text. This is what
            # makes live hints and Tab fixes work on every platform.
            if ev is not None and ev.keysym not in self._NON_EDIT_KEYS:
                self._mark_dirty()
                self._schedule_updates()
            # Any key other than Tab breaks the inline completion cycle.
            if ev is not None and ev.keysym != "Tab":
                self._comp = None

        def _on_click(self, ev=None):
            self.app.hide_completion()
            self.app.hide_hint()
            self._comp = None
            self.update_current_line()
            self.gutter.schedule()
            self.app.update_status()
            self._match_brackets()

        # ---- highlighting --------------------------------------------------

        def _apply_highlight(self, seg_text, base_line, region_end=None):
            t = self.text
            toks = tokenize(seg_text, self.lang)
            retype, _, _, _ = scan_brackets(seg_text, toks)
            li = LineIndex(seg_text)
            start = "%d.0" % base_line
            end = region_end or "end"
            for tag in ALL_TOKEN_TAGS:
                t.tag_remove(tag, start, end)
            b = base_line - 1
            add = t.tag_add
            for idx, (s, e, tt) in enumerate(toks):
                if tt == "brk":
                    tt = retype.get(idx, "brk0")
                l1, c1 = li.line_col(s)
                l2, c2 = li.line_col(e)
                add(tt, "%d.%d" % (l1 + b, c1), "%d.%d" % (l2 + b, c2))

        def highlight_all(self):
            txt = self.get_text()
            if len(txt) > 200000:
                self.highlight_viewport()
                return
            self._apply_highlight(txt, 1)
            self.gutter.schedule()

        def highlight_viewport(self):
            t = self.text
            first = int(t.index("@0,0").split(".")[0])
            h = max(t.winfo_height(), 120)
            last = int(t.index("@0,%d" % h).split(".")[0])
            a = max(1, first - 60)
            z = last + 60
            seg = t.get("%d.0" % a, "%d.end" % z)
            self._apply_highlight(seg, a, region_end="%d.end" % z)
            self.gutter.schedule()

        def highlight_line_now(self):
            t = self.text
            ln = self.cur_line()
            start = "%d.0" % ln
            here = t.tag_names(start)
            if "comment" in here or "string" in here or "codeblock" in here:
                return
            line = t.get(start, "%d.end" % ln)
            toks = tokenize(line, self.lang)
            retype, _, _, _ = scan_brackets(line, toks)
            for tag in ALL_TOKEN_TAGS:
                t.tag_remove(tag, start, "%d.end" % ln)
            for idx, (s, e, tt) in enumerate(toks):
                if tt == "brk":
                    tt = retype.get(idx, "brk0")
                t.tag_add(tt, "%d.%d" % (ln, s), "%d.%d" % (ln, e))
            self.update_current_line()

        # ---- auto-check ----------------------------------------------------

        def _render_issues(self, issues):
            """Paint the issue underlines and gutter markers."""
            t = self.text
            for tag in ISSUE_TAGS:
                t.tag_remove(tag, "1.0", "end")
            self.issue_lines = {}
            last = int(t.index("end-1c").split(".")[0])
            for iss in issues:
                if iss.line < 1 or iss.line > last:
                    continue
                prev = self.issue_lines.get(iss.line)
                if prev is None or SEV_ORDER[iss.severity] < SEV_ORDER[prev]:
                    self.issue_lines[iss.line] = iss.severity
                t.tag_add("iss_" + iss.severity,
                          "%d.%d" % (iss.line, iss.col),
                          "%d.%d" % (iss.line, max(iss.end, iss.col + 1)))
            self.gutter.schedule()

        def run_checks(self, show_hint=True):
            self.check_error = None
            if not self.app.autocheck:
                self.issues = []
                self._render_issues([])
            elif linter_tool(self.lang) is not None:
                # Compiler-backed language: keep the last precise diagnostics
                # on screen and let the async linter refresh them. Re-running
                # the quick built-in check here would briefly blank the real
                # diagnostics between keystrokes (flicker), so we don't.
                self._render_issues(self.issues)
            else:
                txt = self.get_text()
                if len(txt) > 400000:
                    self.issues = []
                else:
                    try:
                        self.issues = check_source(txt, self.lang,
                                                   self.path or self.title)
                    except Exception as ex:
                        # Never fail silently: remember the error so the status
                        # bar shows it instead of a misleading "No problems".
                        self.issues = []
                        self.check_error = "%s: %s" % (type(ex).__name__, ex)
                        _log_error("check_source", ex)
                self._render_issues(self.issues)
            if self is self.app.active_tab():
                self.app.update_issue_ui()
                if show_hint:
                    self.maybe_show_hint()
            # Kick the real compiler/checker in the background for precise
            # diagnostics (offline).
            self._kick_lint(show_hint)

        # ---- external, compiler-grade diagnostics (async, offline) ---------

        def _kick_lint(self, show_hint):
            if not self.app.autocheck:
                return
            if linter_tool(self.lang) is None:
                return
            txt = self.get_text()
            if not txt.strip():
                # Buffer emptied - drop any stale diagnostics.
                if self.issues:
                    self.issues = []
                    self._render_issues([])
                    if self is self.app.active_tab():
                        self.app.update_issue_ui()
                return
            if len(txt) > 150000:
                return
            self._lint_show_hint = show_hint
            if self._lint_running:
                self._lint_pending = True
                return
            self._lint_running = True
            ver = self._version
            lang = self.lang
            threading.Thread(target=self._lint_thread,
                             args=(ver, txt, lang), daemon=True).start()
            self.after(70, self._poll_lint)

        def _lint_thread(self, ver, txt, lang):
            diags = run_linter(lang, txt)
            self._lint_q.put((ver, lang, diags))

        def _poll_lint(self):
            try:
                if not self.winfo_exists():
                    self._lint_running = False
                    return
            except tk.TclError:
                self._lint_running = False
                return
            try:
                while True:
                    self._on_lint_result(*self._lint_q.get_nowait())
            except _queue.Empty:
                pass
            if self._lint_running:
                self.after(70, self._poll_lint)

        def _on_lint_result(self, ver, lang, diags):
            self._lint_running = False
            if lang == self.lang and ver == self._version:
                self._apply_external(diags)
            if self._lint_pending:
                self._lint_pending = False
                self._kick_lint(self._lint_show_hint)

        def _apply_external(self, diags):
            """Replace issues with the compiler's precise diagnostics."""
            lines = self.get_text().split("\n")
            issues = []
            for l, c, sev, msg, fix in diags:
                if l < 1 or l > len(lines):
                    l, c = min(max(1, l), len(lines) or 1), 0
                lt = lines[l - 1] if l - 1 < len(lines) else ""
                c = max(0, min(c, len(lt)))
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", lt[c:])
                if m and m.group(0):
                    end = c + len(m.group(0))
                elif c >= len(lt):
                    c = max(0, len(lt.rstrip()) - 1)
                    end = len(lt) if lt else 1
                else:
                    end = len(lt)
                issues.append(Issue(l, c, max(end, c + 1), sev,
                                    msg, fix))
            issues.sort(key=lambda i: (i.line, SEV_ORDER[i.severity], i.col))
            self.issues = issues[:60]
            self.check_error = None
            self._render_issues(self.issues)
            if self is self.app.active_tab():
                self.app.update_issue_ui()
                if self._lint_show_hint:
                    self.maybe_show_hint()

        def maybe_show_hint(self):
            app = self.app
            if not app.autocheck or not self.issues:
                app.hide_hint()
                return
            ln = self.cur_line()
            for iss in self.issues:
                if iss.line == ln and iss.severity in ("error", "warn"):
                    app.show_hint(self, iss)
                    return
            app.hide_hint()

        def fix_issues(self, issues):
            t = self.text
            sp = LANGS[self.lang]
            t.edit_separator()
            changed = 0
            for iss in sorted([i for i in issues if i.fix],
                              key=lambda i: (-i.line, -i.col)):
                kind, data = iss.fix
                if kind == "append_eof":
                    t.insert("end-1c", data)
                    changed += 1
                    continue
                line = t.get("%d.0" % iss.line, "%d.end" % iss.line)
                if kind == "rename_class":
                    if iss.end <= len(line):
                        new = line[:iss.col] + data + line[iss.end:]
                    else:
                        new = None
                else:
                    new = fixed_line_text(line, iss, sp)
                if new is not None and new != line:
                    t.delete("%d.0" % iss.line, "%d.end" % iss.line)
                    t.insert("%d.0" % iss.line, new)
                    changed += 1
            if changed:
                t.edit_separator()
                self._mark_dirty()
                self.highlight_all()
                self.run_checks(show_hint=False)
                self.app.refresh_outline_if_visible()
            return changed

        def fix_all(self):
            """Deep repair: hand the buffer to the GeckoFix engine."""
            self.app.deep_fix_active()

        def replace_buffer(self, new_text):
            """Swap in repaired text, keeping the caret near where it was."""
            t = self.text
            cur = t.index("insert")
            t.edit_separator()
            t.delete("1.0", "end")
            t.insert("1.0", new_text)
            t.edit_separator()
            try:
                t.mark_set("insert", cur)
            except tk.TclError:
                t.mark_set("insert", "end-1c")
            t.see("insert")
            self._mark_dirty()
            self.highlight_all()
            self.run_checks(show_hint=False)
            self.app.refresh_outline_if_visible()

        # ---- placeholders (skeletons & snippets) ---------------------------

        def _add_placeholder(self, a, b):
            EditorTab._mark_seq[0] += 1
            ms = "phs%d" % EditorTab._mark_seq[0]
            me = "phe%d" % EditorTab._mark_seq[0]
            self.text.mark_set(ms, a)
            self.text.mark_gravity(ms, "left")
            self.text.mark_set(me, b)
            self.text.mark_gravity(me, "right")
            self.placeholder_marks.append((ms, me))

        def clear_placeholders(self):
            for ms, me in self.placeholder_marks:
                try:
                    self.text.mark_unset(ms)
                    self.text.mark_unset(me)
                except tk.TclError:
                    pass
            self.placeholder_marks = []

        def jump_placeholder(self):
            t = self.text
            while self.placeholder_marks:
                ms, me = self.placeholder_marks.pop(0)
                try:
                    a = t.index(ms)
                    b = t.index(me)
                except tk.TclError:
                    continue
                t.mark_unset(ms)
                t.mark_unset(me)
                t.tag_remove("sel", "1.0", "end")
                if a != b:
                    t.tag_add("sel", a, b)
                t.mark_set("insert", b)
                t.see(b)
                t.focus_set()
                return True
            return False

        def expand_snippet(self, word, snip):
            t = self.text
            sp = LANGS[self.lang]
            unit = indent_unit(sp)
            upto = t.get("insert linestart", "insert")
            base = re.match(r"[ \t]*", upto).group(0)
            body = snip.replace("\t", unit).replace("\n", "\n" + base)
            clean, spans = parse_placeholders(body)
            self.clear_placeholders()
            t.edit_separator()
            t.delete("insert-%dc" % len(word), "insert")
            anchor = t.index("insert")
            t.insert("insert", clean)
            for s, e in spans:
                self._add_placeholder("%s+%dc" % (anchor, s),
                                      "%s+%dc" % (anchor, e))
            t.edit_separator()
            self.jump_placeholder()
            self.highlight_all()

        # ---- smart keys ----------------------------------------------------

        def _key_tab(self, ev=None):
            app = self.app
            t = self.text
            pop = app.completion_popup
            if pop and pop.winfo_exists():
                app.accept_completion()
                return "break"
            if self.placeholder_marks and self.jump_placeholder():
                return "break"
            if t.tag_ranges("sel"):
                self.indent_selection(1)
                return "break"
            sp = LANGS[self.lang]
            unit = indent_unit(sp)
            before = t.get("insert linestart", "insert")
            if before.strip() == "":
                # An empty line has nothing to complete - if the file has
                # ERRORS anywhere, Tab repairs the whole file instead of
                # indenting (plain indent when the file is healthy).
                if (app.autocheck and not getattr(app, "_fixing", False)
                        and any(i.severity == "error" for i in self.issues)):
                    app.deep_fix_active()
                    return "break"
                t.insert("insert", unit)
                return "break"
            word = current_word(before)
            after = t.get("insert", "insert lineend").strip()

            # 1) Snippet: a bare keyword at the start of a line expands to a
            #    template. This wins over auto-fix so 'for'+Tab expands the
            #    loop rather than just tacking on a colon.
            fam = LANGS[self.lang]["family"] or self.lang
            snip = SNIPPETS.get(fam, {}).get(word)
            if (snip and not after and
                    before[:len(before) - len(word)].strip() == ""):
                self.expand_snippet(word, snip)
                return "break"

            # 2) Auto-fix the problems on the current line (only when
            #    auto-check is enabled).
            if app.autocheck:
                ln = self.cur_line()
                fixables = [i for i in self.issues if i.line == ln and i.fix]
                if fixables:
                    had_colon = any(i.fix[0] == "colon" for i in fixables)
                    if self.fix_issues(fixables):
                        t.mark_set("insert", "%d.end" % ln)
                        if had_colon:
                            ind = re.match(
                                r"[ \t]*",
                                t.get("%d.0" % ln, "%d.end" % ln)).group(0)
                            t.insert("insert", "\n" + ind + unit)
                        t.see("insert")
                        app.hide_hint()
                        return "break"

            # 3) Completion - always available, even with auto-check off.
            #    Inline and popup-free so it works everywhere (macOS Aqua does
            #    not render borderless popups reliably): the first Tab inserts
            #    the best match, and each further Tab cycles to the next one.
            try:
                if self._complete(before, word):
                    return "break"
            except Exception as ex:
                _log_error("complete", ex)

            # 4) Nothing on this line to complete - but if the FILE still has
            #    problems anywhere, Tab fixes them all (the deep engine).
            if (app.autocheck and not getattr(app, "_fixing", False)
                    and any(i.severity in ("error", "warn")
                            for i in self.issues)):
                app.deep_fix_active()
                return "break"

            # 5) Truly nothing to do - just indent.
            t.insert("insert", unit)
            return "break"

        def _complete(self, before, word):
            """Inline, cycling completion. Returns True if it did something."""
            t = self.text
            c = self._comp
            # Continue cycling if the last completion is still under the caret.
            if (c and t.index("insert") == c["end"]
                    and t.get(c["start"], "insert") == c["cands"][c["idx"]]):
                c["idx"] = (c["idx"] + 1) % len(c["cands"])
                t.edit_separator()
                t.delete(c["start"], "insert")
                t.insert(c["start"], c["cands"][c["idx"]])
                c["end"] = t.index("insert")
                self._comp_status()
                return True
            # Fresh completion: insert the best match, then let further Tabs
            # cycle through the rest.
            cands = compute_completions(self.get_text(), before, self.lang)
            self._comp = None
            if not cands:
                return False
            start = (t.index("insert-%dc" % len(word)) if word
                     else t.index("insert"))
            t.edit_separator()
            if word:
                t.delete(start, "insert")
            t.insert(start, cands[0])
            if len(cands) > 1:
                self._comp = {"start": start, "cands": cands, "idx": 0,
                              "end": t.index("insert")}
                self._comp_status()
            return True

        def _comp_status(self):
            c = self._comp
            if c and self is self.app.active_tab():
                self.app.flash_status(
                    "%s   ▸ %d of %d   (Tab to cycle)"
                    % (c["cands"][c["idx"]], c["idx"] + 1, len(c["cands"])))

        def _clear_completion(self):
            self._comp = None

        def _key_shift_tab(self, ev=None):
            self.indent_selection(-1)
            return "break"

        def indent_selection(self, d):
            t = self.text
            sp = LANGS[self.lang]
            unit = indent_unit(sp)
            had_sel = True
            try:
                a = int(t.index("sel.first").split(".")[0])
                bidx = t.index("sel.last")
                b = int(bidx.split(".")[0])
                if int(bidx.split(".")[1]) == 0 and b > a:
                    b -= 1
            except tk.TclError:
                a = b = self.cur_line()
                had_sel = False
            t.edit_separator()
            for ln in range(a, b + 1):
                line = t.get("%d.0" % ln, "%d.end" % ln)
                if d > 0:
                    if line.strip() or not had_sel:
                        t.insert("%d.0" % ln, unit)
                else:
                    if line.startswith(unit):
                        t.delete("%d.0" % ln, "%d.%d" % (ln, len(unit)))
                    elif line.startswith("\t"):
                        t.delete("%d.0" % ln, "%d.1" % ln)
                    else:
                        m = re.match(r" {1,%d}" % sp["indent"], line)
                        if m:
                            t.delete("%d.0" % ln, "%d.%d" % (ln, m.end()))
            t.edit_separator()
            if had_sel:
                t.tag_add("sel", "%d.0" % a, "%d.end" % b)

        def _key_return(self, ev=None):
            app = self.app
            t = self.text
            pop = app.completion_popup
            if pop and pop.winfo_exists():
                app.accept_completion()
                return "break"
            if t.tag_ranges("sel"):
                t.delete("sel.first", "sel.last")
            t.edit_separator()
            sp = LANGS[self.lang]
            unit = indent_unit(sp)
            before = t.get("insert linestart", "insert")
            after = t.get("insert", "insert lineend")
            ind = re.match(r"[ \t]*", before).group(0)
            code = split_code_comment(before, sp["line_comment"])[0].rstrip()
            extra = ""
            if self.lang == "python" and code.endswith(":"):
                extra = unit
            elif code and code[-1] in BRK_PAIR:
                extra = unit
                closer = BRK_PAIR[code[-1]]
                if after.lstrip().startswith(closer):
                    t.insert("insert", "\n" + ind + extra + "\n" + ind)
                    t.mark_set("insert", "insert-%dc" % (len(ind) + 1))
                    t.see("insert")
                    app.hide_hint()
                    return "break"
            elif self.lang == "python" and code.strip():
                w = code.strip().split(" ")[0]
                if (w in ("return", "pass", "break", "continue", "raise")
                        and len(ind) >= len(unit)):
                    ind = ind[:len(ind) - len(unit)]
            t.insert("insert", "\n" + ind + extra)
            t.see("insert")
            app.hide_completion()
            return "break"

        def _key_backspace(self, ev=None):
            t = self.text
            if t.tag_ranges("sel"):
                return None
            prev = t.get("insert-1c", "insert")
            nxt = t.get("insert", "insert+1c")
            if prev and prev + nxt in ("()", "[]", "{}", '""', "''", "``"):
                t.delete("insert-1c", "insert+1c")
                return "break"
            before = t.get("insert linestart", "insert")
            sp = LANGS[self.lang]
            if before and before.strip() == "" and sp["indent_char"] == " ":
                w = sp["indent"]
                back = len(before) % w or w
                if back > 1 and len(before) >= back:
                    t.delete("insert-%dc" % back, "insert")
                    return "break"
            return None

        def _key_escape(self, ev=None):
            app = self.app
            app.hide_completion()
            app.hide_hint()
            self.clear_placeholders()
            self.text.tag_remove("find_match", "1.0", "end")
            app.hide_findbar()
            return "break"

        def _key_updown(self, d):
            pop = self.app.completion_popup
            if pop and pop.winfo_exists():
                pop.move(d)
                return "break"
            return None

        def _key_open(self, ev, ch, close):
            if ev.char != ch:
                return None
            t = self.text
            if t.tag_ranges("sel"):
                s = t.index("sel.first")
                e = t.index("sel.last")
                t.insert(e, close)
                t.insert(s, ch)
                t.tag_remove("sel", "1.0", "end")
                t.mark_set("insert", "%s+2c" % e)
                return "break"
            t.insert("insert", ch + close)
            t.mark_set("insert", "insert-1c")
            return "break"

        def _key_close(self, ev, ch):
            if ev.char != ch:
                return None
            t = self.text
            if t.get("insert", "insert+1c") == ch:
                t.mark_set("insert", "insert+1c")
                return "break"
            sp = LANGS[self.lang]
            before = t.get("insert linestart", "insert")
            if (ch == "}" and before and before.strip() == ""
                    and sp["indent_char"] == " "):
                back = len(before) % sp["indent"] or sp["indent"]
                if len(before) >= back:
                    t.delete("insert-%dc" % back, "insert")
            return None

        def _key_quote(self, ev, q):
            if ev.char != q:
                return None
            sp = LANGS[self.lang]
            if q == "`":
                if not sp["backtick"] and self.lang != "markdown":
                    return None
            elif q not in sp["strings"]:
                return None
            t = self.text
            if t.tag_ranges("sel"):
                s = t.index("sel.first")
                e = t.index("sel.last")
                t.insert(e, q)
                t.insert(s, q)
                t.tag_remove("sel", "1.0", "end")
                t.mark_set("insert", "%s+2c" % e)
                return "break"
            if t.get("insert", "insert+1c") == q:
                t.mark_set("insert", "insert+1c")
                return "break"
            tags = t.tag_names("insert")
            if "comment" in tags or "string" in tags:
                return None
            prev = t.get("insert-1c", "insert")
            if q == "'" and (prev.isalnum() or prev == "'"):
                return None
            t.insert("insert", q + q)
            t.mark_set("insert", "insert-1c")
            return "break"

        # ---- brackets match, goto, comments --------------------------------

        def _match_brackets(self):
            t = self.text
            t.tag_remove("brk_match", "1.0", "end")
            for probe in ("insert-1c", "insert"):
                ch = t.get(probe, "%s+1c" % probe)
                if ch in "()[]{}":
                    txt = self.get_text()
                    if len(txt) > 200000:
                        return
                    pos = len(t.get("1.0", probe))
                    part = self._find_partner(txt, pos)
                    if part is not None:
                        li = LineIndex(txt)
                        for p in (pos, part):
                            t.tag_add("brk_match", li.tk(p),
                                      "%s+1c" % li.tk(p))
                    return

        @staticmethod
        def _find_partner(txt, pos):
            ch = txt[pos]
            if ch in BRK_PAIR:
                target, rng = BRK_PAIR[ch], range(pos + 1,
                                                  min(len(txt), pos + 20000))
            else:
                target, rng = BRK_MATCH[ch], range(pos - 1,
                                                   max(-1, pos - 20000), -1)
            depth = 0
            for i in rng:
                c = txt[i]
                if c == ch:
                    depth += 1
                elif c == target:
                    if depth == 0:
                        return i
                    depth -= 1
            return None

        def toggle_breakpoint(self, ln):
            if ln in self.breakpoints:
                self.breakpoints.discard(ln)
            else:
                self.breakpoints.add(ln)
            self.gutter.schedule()
            self.app.flash_status(
                "Breakpoint %s line %d - Debug (%sR with shift) stops there"
                % ("removed from" if ln not in self.breakpoints else "set on",
                   ln, "⌘" if IS_MAC else "Ctrl+"))

        def goto_line(self, n):
            t = self.text
            n = max(1, min(n, int(t.index("end-1c").split(".")[0])))
            t.mark_set("insert", "%d.0" % n)
            t.see("insert")
            t.focus_set()
            self.update_current_line()
            self.gutter.schedule()

        def goto_issue(self, iss):
            t = self.text
            t.mark_set("insert", "%d.%d" % (iss.line, iss.col))
            t.see("insert")
            t.focus_set()
            self.update_current_line()
            self.gutter.schedule()

        def toggle_comment(self):
            t = self.text
            sp = LANGS[self.lang]
            lc = sp["line_comment"]
            try:
                a = int(t.index("sel.first").split(".")[0])
                bidx = t.index("sel.last")
                b = int(bidx.split(".")[0])
                if int(bidx.split(".")[1]) == 0 and b > a:
                    b -= 1
            except tk.TclError:
                a = b = self.cur_line()
            t.edit_separator()
            if lc:
                lines = [t.get("%d.0" % ln, "%d.end" % ln)
                         for ln in range(a, b + 1)]
                nonblank = [l for l in lines if l.strip()]
                all_comm = bool(nonblank) and all(
                    l.lstrip().startswith(lc) for l in nonblank)
                if all_comm:
                    for i, ln in enumerate(range(a, b + 1)):
                        l = lines[i]
                        if not l.strip():
                            continue
                        p = l.index(lc)
                        w = len(lc)
                        if l[p + w:p + w + 1] == " ":
                            w += 1
                        t.delete("%d.%d" % (ln, p), "%d.%d" % (ln, p + w))
                else:
                    ind = min((len(l) - len(l.lstrip()) for l in nonblank),
                              default=0)
                    for ln in range(a, b + 1):
                        if t.get("%d.0" % ln, "%d.end" % ln).strip():
                            t.insert("%d.%d" % (ln, ind), lc + " ")
            elif sp["block_comment"]:
                o, c = sp["block_comment"]
                for ln in range(a, b + 1):
                    line = t.get("%d.0" % ln, "%d.end" % ln)
                    st = line.strip()
                    if not st:
                        continue
                    ind = line[:len(line) - len(line.lstrip())]
                    if st.startswith(o) and st.endswith(c):
                        inner = st[len(o):len(st) - len(c)].strip()
                        new = ind + inner
                    else:
                        new = ind + o + " " + st + " " + c
                    t.delete("%d.0" % ln, "%d.end" % ln)
                    t.insert("%d.0" % ln, new)
            t.edit_separator()
            self.highlight_all()
            self.run_checks(show_hint=False)

        # ---- saving --------------------------------------------------------

        def save_to(self, path):
            txt = self.get_text()
            data = txt if (not txt or txt.endswith("\n")) else txt + "\n"
            with open(path, "w", encoding="utf-8") as f:
                f.write(data)
            self.path = path
            self.title = os.path.basename(path)
            new_lang = detect_language(path, txt.split("\n", 1)[0])
            if new_lang != "text" and new_lang != self.lang:
                self.set_language(new_lang)
            self.dirty = False
            return True

        def set_language(self, lang_id):
            if lang_id not in LANGS:
                return
            self.lang = lang_id
            self.apply_font()
            self.highlight_all()
            self.run_checks(show_hint=False)
            self.app.update_status()
            self.app.refresh_outline_if_visible()

    class OutputPanel(tk.Frame):
        """Run/Debug console with live output and an interactive stdin box."""

        def __init__(self, master, app):
            super().__init__(master, bg=THEME["bg_panel"])
            self.app = app
            self.visible = False
            head = tk.Frame(self, bg=THEME["bg_panel"])
            head.pack(fill="x")
            tk.Label(head, text="OUTPUT", bg=THEME["bg_panel"],
                     fg=THEME["fg_dim"], font=app.small_font)\
                .pack(side="left", padx=(10, 6), pady=2)
            self.state_lbl = tk.Label(head, text="", bg=THEME["bg_panel"],
                                      fg=THEME["fg_dim"], font=app.small_font)
            self.state_lbl.pack(side="left")
            FlatButton(head, "✕", self.hide, font=app.small_font,
                       padx=7, pady=1).pack(side="right", padx=(0, 6), pady=2)
            FlatButton(head, "Clear", self.clear, font=app.small_font,
                       padx=7, pady=1).pack(side="right", pady=2)
            mid = tk.Frame(self, bg=THEME["bg_panel"])
            mid.pack(fill="both", expand=True)
            self.text = tk.Text(mid, height=11, bg="#0a100d", fg=THEME["fg"],
                                bd=0, highlightthickness=0, wrap="word",
                                state="disabled", font=app.mono_font,
                                padx=9, pady=6,
                                insertbackground=THEME["caret"],
                                selectbackground=THEME["sel"])
            vs = tk.Scrollbar(mid, orient="vertical", command=self.text.yview)
            self.text.configure(yscrollcommand=vs.set)
            self.text.pack(side="left", fill="both", expand=True)
            vs.pack(side="right", fill="y")
            self.text.tag_configure("out", foreground=THEME["fg"])
            self.text.tag_configure("err", foreground=THEME["error"])
            self.text.tag_configure("info", foreground=THEME["info"])
            self.text.tag_configure("cmd", foreground=THEME["fg_dim"])
            self.text.tag_configure("in", foreground=THEME["accent"])
            self.text.tag_configure("ok", foreground=THEME["ok"])
            # Debugger controls (shown during pdb / lldb / gdb sessions)
            self.dbgrow = tk.Frame(self, bg=THEME["bg_panel"])
            for label, cmd in (("▷ Next", "n"), ("↓ Step", "s"),
                               ("↑ Out", "r"), ("▶ Continue", "c"),
                               ("👁 Vars", "p {k: v for k, v in "
                                          "locals().items() "
                                          "if not k.startswith('_')}"),
                               ("≡ Where", "w"), ("✕ Quit", "q")):
                FlatButton(self.dbgrow, label,
                           (lambda c=cmd: self.send_cmd(c)),
                           font=app.small_font, padx=8, pady=1)\
                    .pack(side="left", padx=3, pady=3)
            tk.Label(self.dbgrow, text="click the gutter's left edge to set "
                                       "breakpoints", bg=THEME["bg_panel"],
                     fg=THEME["fg_faint"], font=app.small_font)\
                .pack(side="left", padx=8)
            row = tk.Frame(self, bg=THEME["bg_panel"])
            row.pack(fill="x")
            tk.Label(row, text="stdin ▸", bg=THEME["bg_panel"],
                     fg=THEME["fg_dim"], font=app.small_font)\
                .pack(side="left", padx=(10, 4))
            self.entry = tk.Entry(row, bg=THEME["bg_input"], fg=THEME["fg"],
                                  insertbackground=THEME["caret"], bd=0,
                                  highlightthickness=1,
                                  highlightbackground=THEME["border"],
                                  highlightcolor=THEME["accent_dark"],
                                  font=app.mono_font)
            self.entry.pack(side="left", fill="x", expand=True, pady=4)
            self.entry.bind("<Return>", self.send)
            FlatButton(row, "Send", self.send, font=app.small_font,
                       padx=8, pady=1).pack(side="left", padx=6)

        def set_debug_buttons(self, on):
            if on:
                self.dbgrow.pack(fill="x", before=self.entry.master)
            else:
                self.dbgrow.pack_forget()

        def send_cmd(self, cmd):
            r = self.app.runner
            if r and r.alive():
                self.append("in", "▸ %s\n" % cmd)
                r.send_line(cmd)
            else:
                self.append("info", "The debugger is not running.\n")

        def show(self):
            if not self.visible:
                self.grid()
                self.visible = True

        def hide(self):
            if self.visible:
                self.grid_remove()
                self.visible = False

        def toggle(self):
            (self.hide if self.visible else self.show)()

        def clear(self):
            self.text.configure(state="normal")
            self.text.delete("1.0", "end")
            self.text.configure(state="disabled")

        def append(self, tag, s):
            t = self.text
            t.configure(state="normal")
            t.insert("end", s, (tag,))
            if len(t.get("1.0", "end-1c")) > 400000:
                t.delete("1.0", "1.0+100000c")
            t.see("end")
            t.configure(state="disabled")

        def begin_static(self, title):
            self.show()
            self.set_debug_buttons(False)
            self.append("cmd", "\n── %s ──\n" % title)
            self.state_lbl.config(text="")

        def begin_run(self, name, debug):
            self.show()
            what = "Debug" if debug else "Run"
            self.append("cmd", "\n── %s %s · %s ──\n"
                        % (what, name, time.strftime("%H:%M:%S")))
            self.state_lbl.config(text="running…", fg=THEME["warn"])
            self.entry.focus_set()

        def poll(self, runner):
            if runner is not self.app.runner:
                return
            for _ in range(300):
                try:
                    ev = runner.events.get_nowait()
                except _queue.Empty:
                    break
                if ev[0] == "done":
                    rc, secs = ev[1], ev[2]
                    tag = "ok" if rc == 0 else "err"
                    self.append(tag, "\n[finished with exit code %d in %.2fs]\n"
                                % (rc, secs))
                    self.state_lbl.config(
                        text="done (%d)" % rc,
                        fg=THEME["ok"] if rc == 0 else THEME["error"])
                    self.app.runner = None
                    return
                self.append(ev[0], ev[1])
            self.after(50, lambda: self.poll(runner))

        def send(self, ev=None):
            line = self.entry.get()
            self.entry.delete(0, "end")
            r = self.app.runner
            if r and r.alive():
                self.append("in", "▸ %s\n" % line)
                r.send_line(line)
            else:
                self.append("info", "No program is waiting for input.\n")

    class FindBar(tk.Frame):
        def __init__(self, master, app):
            super().__init__(master, bg=THEME["bg_panel"])
            self.app = app
            self.matches = []
            self.at = -1
            self.case = False

            def mk_entry():
                e = tk.Entry(self, bg=THEME["bg_input"], fg=THEME["fg"],
                             insertbackground=THEME["caret"], bd=0,
                             highlightthickness=1, width=22,
                             highlightbackground=THEME["border"],
                             highlightcolor=THEME["accent_dark"],
                             font=app.small_font)
                return e
            tk.Label(self, text="Find", bg=THEME["bg_panel"], fg=THEME["fg_dim"],
                     font=app.small_font).pack(side="left", padx=(10, 4), pady=5)
            self.find_e = mk_entry()
            self.find_e.pack(side="left", pady=5)
            self.count_lbl = tk.Label(self, text="", bg=THEME["bg_panel"],
                                      fg=THEME["fg_dim"], font=app.small_font)
            self.count_lbl.pack(side="left", padx=6)
            self.case_btn = FlatButton(self, "Aa", self.toggle_case,
                                       font=app.small_font, padx=6, pady=1)
            self.case_btn.pack(side="left", padx=2, pady=4)
            FlatButton(self, "◀", lambda: self.step(-1), font=app.small_font,
                       padx=6, pady=1).pack(side="left", padx=2, pady=4)
            FlatButton(self, "▶", lambda: self.step(1), font=app.small_font,
                       padx=6, pady=1).pack(side="left", padx=2, pady=4)
            tk.Label(self, text="Replace", bg=THEME["bg_panel"],
                     fg=THEME["fg_dim"], font=app.small_font)\
                .pack(side="left", padx=(14, 4))
            self.rep_e = mk_entry()
            self.rep_e.pack(side="left", pady=5)
            FlatButton(self, "Replace", self.replace_one, font=app.small_font,
                       padx=7, pady=1).pack(side="left", padx=3, pady=4)
            FlatButton(self, "All", self.replace_all, font=app.small_font,
                       padx=7, pady=1).pack(side="left", pady=4)
            FlatButton(self, "✕", self.hide, font=app.small_font,
                       padx=7, pady=1).pack(side="right", padx=8, pady=4)
            for e in (self.find_e, self.rep_e):
                e.bind("<Escape>", lambda ev: self.hide())
            self.find_e.bind("<KeyRelease>", self._typed)
            self.find_e.bind("<Return>", lambda ev: self.step(1))
            self.find_e.bind("<Shift-Return>", lambda ev: self.step(-1))
            self.rep_e.bind("<Return>", lambda ev: self.replace_one())

        def toggle_case(self):
            self.case = not self.case
            self.case_btn.configure(
                fg=THEME["accent"] if self.case else THEME["fg"])
            self.case_btn.c_fg = (THEME["accent"] if self.case
                                  else THEME["fg"])
            self.search()

        def show(self):
            tab = self.app.active_tab()
            if not tab:
                return
            if not self.winfo_manager():
                self.pack(fill="x", before=self.app.body)
            try:
                sel = tab.text.get("sel.first", "sel.last")
                if sel and "\n" not in sel:
                    self.find_e.delete(0, "end")
                    self.find_e.insert(0, sel)
            except tk.TclError:
                pass
            self.find_e.focus_set()
            self.find_e.select_range(0, "end")
            self.search()

        def hide(self):
            if self.winfo_manager():
                self.pack_forget()
            tab = self.app.active_tab()
            if tab:
                tab.text.tag_remove("find_match", "1.0", "end")
                tab.text.focus_set()

        def _typed(self, ev=None):
            if ev and ev.keysym in ("Return", "Shift_L", "Shift_R", "Escape"):
                return
            self.search()

        def _pattern(self):
            return self.find_e.get()

        def search(self):
            tab = self.app.active_tab()
            if not tab:
                return
            t = tab.text
            t.tag_remove("find_match", "1.0", "end")
            self.matches = []
            self.at = -1
            pat = self._pattern()
            if not pat:
                self.count_lbl.config(text="")
                return
            use_re = pat.startswith("-")
            if use_re:
                pat_s = "".join(ch if ch.isalnum() else "\\" + ch for ch in pat)
            else:
                pat_s = pat
            idx = "1.0"
            for _ in range(3000):
                idx = t.search(pat_s, idx, stopindex="end",
                               nocase=not self.case, regexp=use_re)
                if not idx:
                    break
                end = "%s+%dc" % (idx, len(pat))
                t.tag_add("find_match", idx, end)
                self.matches.append(idx)
                idx = end
            n = len(self.matches)
            self.count_lbl.config(text="%d match%s" % (n, "" if n == 1 else "es"))

        def step(self, d):
            if not self.matches:
                self.search()
            if not self.matches:
                return
            tab = self.app.active_tab()
            if not tab:
                return
            t = tab.text
            self.at = (self.at + d) % len(self.matches)
            idx = self.matches[self.at]
            end = "%s+%dc" % (idx, len(self._pattern()))
            t.tag_remove("sel", "1.0", "end")
            t.tag_add("sel", idx, end)
            t.mark_set("insert", end)
            t.see(idx)
            tab.update_current_line()
            tab.gutter.schedule()
            self.count_lbl.config(text="%d of %d"
                                  % (self.at + 1, len(self.matches)))

        def replace_one(self):
            tab = self.app.active_tab()
            if not tab or not self._pattern():
                return
            t = tab.text
            pat = self._pattern()
            try:
                sel = t.get("sel.first", "sel.last")
            except tk.TclError:
                sel = ""
            same = (sel == pat) if self.case else (sel.lower() == pat.lower())
            if same and sel:
                t.edit_separator()
                t.delete("sel.first", "sel.last")
                t.insert("insert", self.rep_e.get())
                t.edit_separator()
                self.search()
            self.step(1)

        def replace_all(self):
            tab = self.app.active_tab()
            pat = self._pattern()
            if not tab or not pat:
                return
            t = tab.text
            rep = self.rep_e.get()
            t.edit_separator()
            idx = "1.0"
            n = 0
            for _ in range(20000):
                idx = t.search(pat, idx, stopindex="end", nocase=not self.case)
                if not idx:
                    break
                t.delete(idx, "%s+%dc" % (idx, len(pat)))
                t.insert(idx, rep)
                idx = "%s+%dc" % (idx, len(rep))
                n += 1
            t.edit_separator()
            self.search()
            self.app.flash_status("Replaced %d occurrence%s"
                                  % (n, "" if n == 1 else "s"))
            tab.highlight_all()
            tab.run_checks(show_hint=False)

    class OutlinePane(tk.Frame):
        """Left-side source outline for fast jumps in large files."""

        def __init__(self, master, app):
            super().__init__(master, bg=THEME["bg_panel"], width=250)
            self.app = app
            self.visible = False
            self.pack_propagate(False)
            head = tk.Frame(self, bg=THEME["bg_panel"])
            head.pack(fill="x")
            tk.Label(head, text="OUTLINE", bg=THEME["bg_panel"],
                     fg=THEME["fg_dim"], font=app.small_font)\
                .pack(side="left", padx=(10, 6), pady=6)
            FlatButton(head, "Refresh", self.refresh, font=app.small_font,
                       padx=7, pady=1).pack(side="right", pady=4)
            FlatButton(head, "✕", self.hide, font=app.small_font,
                       padx=7, pady=1).pack(side="right", padx=(0, 4), pady=4)
            wrap = tk.Frame(self, bg=THEME["bg_panel"])
            wrap.pack(fill="both", expand=True)
            self.canvas = tk.Canvas(wrap, bg=THEME["bg_panel"],
                                    highlightthickness=0, bd=0)
            self.scroll = tk.Scrollbar(wrap, orient="vertical",
                                       command=self.canvas.yview)
            self.inner = tk.Frame(self.canvas, bg=THEME["bg_panel"])
            self.canvas.configure(yscrollcommand=self.scroll.set)
            self.canvas.pack(side="left", fill="both", expand=True)
            self.scroll.pack(side="right", fill="y")
            self.window = self.canvas.create_window((0, 0), window=self.inner,
                                                    anchor="nw")
            self.inner.bind("<Configure>", lambda e: self.canvas.configure(
                scrollregion=self.canvas.bbox("all")))
            self.canvas.bind("<Configure>", lambda e:
                             self.canvas.itemconfigure(self.window, width=e.width))

        def show(self):
            if not self.visible:
                self.pack(side="left", fill="y", before=self.app.editor_area)
                self.visible = True
            self.refresh()

        def hide(self):
            if self.visible:
                self.pack_forget()
                self.visible = False

        def toggle(self):
            (self.hide if self.visible else self.show)()

        def refresh(self):
            for w in self.inner.winfo_children():
                w.destroy()
            tab = self.app.active_tab()
            if not tab:
                self._empty("Open a file to see its outline.")
                return
            items = outline_items(tab.get_text(), tab.lang)
            if not items:
                self._empty("No outline items in this file yet.")
                return
            for item in items:
                self._row(tab, item)

        def _empty(self, text):
            tk.Label(self.inner, text=text, bg=THEME["bg_panel"],
                     fg=THEME["fg_faint"], font=self.app.small_font,
                     justify="left", wraplength=210)\
                .pack(anchor="w", padx=12, pady=10)

        def _row(self, tab, item):
            row = tk.Frame(self.inner, bg=THEME["bg_panel"], cursor="hand2")
            row.pack(fill="x", padx=4, pady=1)
            pad = 8 + item.level * 14
            text = "%4d  %s %s" % (item.line, item.kind, item.name)
            lbl = tk.Label(row, text=text, anchor="w", bg=THEME["bg_panel"],
                           fg=THEME["fg"], font=self.app.small_font,
                           cursor="hand2", padx=pad, pady=3)
            lbl.pack(fill="x")

            def jump(ev=None, line=item.line, tb=tab):
                self.app.activate(tb)
                tb.goto_line(line)
            for w in (row, lbl):
                w.bind("<Button-1>", jump)
                w.bind("<Enter>", lambda e, ww=w: ww.configure(bg=THEME["bg_hover"]))
                w.bind("<Leave>", lambda e, ww=w: ww.configure(bg=THEME["bg_panel"]))

    class HomePane(tk.Frame):
        """Welcome screen: new file, open file, recent files."""

        def __init__(self, master, app):
            super().__init__(master, bg=THEME["bg"])
            self.app = app
            self.inner = tk.Frame(self, bg=THEME["bg"])
            self.inner.place(relx=0.5, rely=0.44, anchor="center")

        def _gecko(self, cv):
            g1, g2 = THEME["accent"], THEME["accent_dark"]
            cv.create_arc(6, 44, 66, 102, start=100, extent=225, style="arc",
                          outline=g2, width=7)
            cv.create_oval(38, 48, 106, 92, fill=g1, outline="")
            cv.create_oval(88, 30, 126, 68, fill=g1, outline="")
            for x, y in ((52, 86), (84, 86)):
                cv.create_line(x, y, x - 8, y + 14, fill=g2, width=5,
                               capstyle="round")
                cv.create_line(x + 14, y, x + 22, y + 14, fill=g2, width=5,
                               capstyle="round")
            cv.create_oval(106, 41, 115, 50, fill="#0c110f", outline="")
            cv.create_oval(111, 43, 114, 46, fill="#eafff2", outline="")
            for x, y in ((56, 60), (72, 68), (62, 76)):
                cv.create_oval(x, y, x + 6, y + 6, fill=g2, outline="")

        def refresh(self):
            app = self.app
            for w in self.inner.winfo_children():
                w.destroy()
            cv = tk.Canvas(self.inner, width=136, height=116, bg=THEME["bg"],
                           highlightthickness=0)
            cv.pack()
            self._gecko(cv)
            tk.Label(self.inner, text=APP, bg=THEME["bg"], fg=THEME["fg"],
                     font=app.ui_big).pack(pady=(4, 0))
            tk.Label(self.inner,
                     text="Write code fast — colorful, smart, 100% offline.",
                     bg=THEME["bg"], fg=THEME["fg_dim"],
                     font=app.ui_font).pack(pady=(2, 16))
            row = tk.Frame(self.inner, bg=THEME["bg"])
            row.pack()
            mod = "⌘" if IS_MAC else "Ctrl+"
            FlatButton(row, "＋  New File   (%sN)" % mod,
                       app.new_file_dialog, "primary", padx=18, pady=9,
                       font=app.ui_font).pack(side="left", padx=6)
            FlatButton(row, "📂  Open File…   (%sO)" % mod,
                       app.open_dialog, "ghost", padx=18, pady=9,
                       font=app.ui_font).pack(side="left", padx=6)
            recents = [p for p in app.settings.get("recent", [])
                       if os.path.exists(p)][:6]
            if recents:
                tk.Label(self.inner, text="RECENT", bg=THEME["bg"],
                         fg=THEME["fg_faint"], font=app.small_font)\
                    .pack(pady=(22, 4))
                for p in recents:
                    r = tk.Frame(self.inner, bg=THEME["bg"], cursor="hand2")
                    r.pack(fill="x", pady=1)
                    a = tk.Label(r, text=os.path.basename(p), bg=THEME["bg"],
                                 fg=THEME["accent"], font=app.ui_font)
                    a.pack(side="left")
                    b = tk.Label(r, text="  " + shorten_home(os.path.dirname(p)),
                                 bg=THEME["bg"], fg=THEME["fg_faint"],
                                 font=app.small_font)
                    b.pack(side="left")
                    for w in (r, a, b):
                        w.bind("<Button-1>",
                               lambda e, pp=p: app.open_path(pp))
                        w.bind("<Enter>",
                               lambda e, aa=a: aa.configure(fg="#7fe9b8"))
                        w.bind("<Leave>",
                               lambda e, aa=a: aa.configure(fg=THEME["accent"]))
            tk.Label(self.inner,
                     text="Tab auto-completes and auto-fixes  ·  hints appear "
                          "as you type  ·  %sR runs your code" % mod,
                     bg=THEME["bg"], fg=THEME["fg_faint"],
                     font=app.small_font).pack(pady=(26, 0))

    class GeskoApp(tk.Tk):
        def __init__(self, paths=()):
            super().__init__()
            self.title(APP)
            self.configure(bg=THEME["bg"])
            self.settings = self._load_settings()
            self.geometry(self.settings.get("geometry") or "1180x760")
            self.minsize(860, 540)

            fam = pick_family(self, ("SF Mono", "Menlo", "Monaco",
                                     "JetBrains Mono", "Fira Code",
                                     "Cascadia Code", "Consolas",
                                     "DejaVu Sans Mono", "Ubuntu Mono",
                                     "Liberation Mono", "Courier New"),
                              "Courier")
            size = int(self.settings.get("font_size", 13))
            self.mono_font = tkfont.Font(family=fam, size=size)
            self.mono_bold = tkfont.Font(family=fam, size=size, weight="bold")
            self.mono_italic = tkfont.Font(family=fam, size=size,
                                           slant="italic")
            ufam = pick_family(self, ("Helvetica Neue", "SF Pro Text",
                                      "Segoe UI", "DejaVu Sans", "Helvetica",
                                      "Arial"), "Helvetica")
            self.ui_font = tkfont.Font(family=ufam, size=13)
            self.ui_big = tkfont.Font(family=ufam, size=30, weight="bold")
            self.small_font = tkfont.Font(family=ufam, size=11)

            self.autocheck = bool(self.settings.get("autocheck", True))
            self.autocheck_var = tk.BooleanVar(value=self.autocheck)
            self.tabs = []
            self._active = None
            self.completion_popup = None
            self._completion_ctx = None
            self.hint_popup = None
            self._hint_key = None
            self.runner = None
            self._flash_job = None

            self._build_menu()
            self._build_ui()
            self._bind_keys()
            self._set_icon()
            self.protocol("WM_DELETE_WINDOW", self.quit_app)
            if IS_MAC:
                for cmd, fn in (("tk::mac::Quit", self.quit_app),
                                ("tk::mac::OpenDocument", self._mac_open_docs)):
                    try:
                        self.createcommand(cmd, fn)
                    except tk.TclError:
                        pass

            opened = False
            for p in paths:
                if os.path.exists(p):
                    self.open_path(os.path.abspath(p))
                    opened = True
            if not opened:
                self.show_home()

        # ---- construction --------------------------------------------------

        def _build_ui(self):
            self.topbar = tk.Frame(self, bg=THEME["bg_panel"])
            self.topbar.pack(side="top", fill="x")
            right = tk.Frame(self.topbar, bg=THEME["bg_panel"])
            right.pack(side="right", padx=6)
            FlatButton(right, "▶ Run", self.run_active, "primary",
                       font=self.small_font, padx=10, pady=3)\
                .pack(side="left", padx=3, pady=4)
            FlatButton(right, "◆ Debug", lambda: self.run_active(True),
                       font=self.small_font, padx=10, pady=3)\
                .pack(side="left", padx=3, pady=4)
            FlatButton(right, "■ Stop", self.stop_run,
                       font=self.small_font, padx=10, pady=3)\
                .pack(side="left", padx=3, pady=4)
            FlatButton(self.topbar, "☰ Outline", self.toggle_outline,
                       font=self.small_font, padx=10, pady=3)\
                .pack(side="left", padx=(6, 3), pady=4)
            self.tabrow = tk.Frame(self.topbar, bg=THEME["bg_panel"])
            self.tabrow.pack(side="left", fill="x", expand=True)

            bottom = tk.Frame(self, bg=THEME["bg"])
            bottom.pack(side="bottom", fill="x")
            bottom.columnconfigure(0, weight=1)
            self.output = OutputPanel(bottom, self)
            self.output.grid(row=0, column=0, sticky="ew")
            self.output.grid_remove()
            self.hintbar = tk.Frame(bottom, bg=THEME["bg_panel"])
            self.hintbar.grid(row=1, column=0, sticky="ew")
            self.hintbar.grid_remove()
            self.status = tk.Frame(bottom, bg=THEME["bg_status"])
            self.status.grid(row=2, column=0, sticky="ew")
            self._build_status()

            self.body = tk.Frame(self, bg=THEME["bg"])
            self.body.pack(side="top", fill="both", expand=True)
            self.outline = OutlinePane(self.body, self)
            self.editor_area = tk.Frame(self.body, bg=THEME["bg"])
            self.editor_area.pack(side="left", fill="both", expand=True)
            self.findbar = FindBar(self, self)
            self.home = HomePane(self.editor_area, self)

        def _build_status(self):
            s = self.status
            self.st_issues = tk.Label(s, text="", bg=THEME["bg_status"],
                                      fg=THEME["ok"], font=self.small_font,
                                      cursor="hand2")
            self.st_issues.pack(side="left", padx=(10, 6), pady=2)
            self.st_issues.bind("<Button-1>", lambda e: self.goto_first_issue())
            self.st_msg = tk.Label(s, text="", bg=THEME["bg_status"],
                                   fg=THEME["fg_dim"], font=self.small_font)
            self.st_msg.pack(side="left", padx=6)
            for name, cb in (("st_enc", None), ("st_check", self.toggle_autocheck),
                             ("st_indent", None), ("st_lang", self.language_menu),
                             ("st_pos", None)):
                lbl = tk.Label(s, text="", bg=THEME["bg_status"],
                               fg=THEME["fg_dim"], font=self.small_font,
                               cursor=("hand2" if cb else "arrow"))
                lbl.pack(side="right", padx=8, pady=2)
                if cb:
                    lbl.bind("<Button-1>", lambda e, f=cb: f())
                setattr(self, name, lbl)
            self.st_enc.config(text="UTF-8")

        def _build_menu(self):
            m = tk.Menu(self)

            def acc(k, shift=False):
                if IS_MAC:
                    return ("Shift-Command-%s" if shift else "Command-%s") % k
                return ("Ctrl+Shift+%s" if shift else "Ctrl+%s") % k

            if IS_MAC:
                apple = tk.Menu(m, name="apple")
                apple.add_command(label="About " + APP, command=self.show_about)
                m.add_cascade(menu=apple)
            fm = tk.Menu(m, tearoff=0)
            fm.add_command(label="New File…", accelerator=acc("N"),
                           command=self.new_file_dialog)
            fm.add_command(label="Open…", accelerator=acc("O"),
                           command=self.open_dialog)
            self.recent_menu = tk.Menu(fm, tearoff=0,
                                       postcommand=self._fill_recent)
            fm.add_cascade(label="Open Recent", menu=self.recent_menu)
            fm.add_separator()
            fm.add_command(label="Save", accelerator=acc("S"),
                           command=self.save_active)
            fm.add_command(label="Save As…", accelerator=acc("S", True),
                           command=self.save_as_active)
            fm.add_separator()
            fm.add_command(label="Close Tab", accelerator=acc("W"),
                           command=self.close_active)
            if not IS_MAC:
                fm.add_separator()
                fm.add_command(label="Quit", accelerator="Ctrl+Q",
                               command=self.quit_app)
            m.add_cascade(label="File", menu=fm)

            em = tk.Menu(m, tearoff=0)
            em.add_command(label="Undo", accelerator=acc("Z"),
                           command=lambda: self._ev("<<Undo>>"))
            em.add_command(label="Redo", accelerator=acc("Z", True),
                           command=lambda: self._ev("<<Redo>>"))
            em.add_separator()
            em.add_command(label="Cut", accelerator=acc("X"),
                           command=lambda: self._ev("<<Cut>>"))
            em.add_command(label="Copy", accelerator=acc("C"),
                           command=lambda: self._ev("<<Copy>>"))
            em.add_command(label="Paste", accelerator=acc("V"),
                           command=lambda: self._ev("<<Paste>>"))
            em.add_command(label="Select All", accelerator=acc("A"),
                           command=self.select_all)
            em.add_separator()
            em.add_command(label="Find & Replace…", accelerator=acc("F"),
                           command=self.show_findbar)
            em.add_command(label="Go to Line…", accelerator=acc("L"),
                           command=self.goto_dialog)
            em.add_separator()
            em.add_command(label="Toggle Comment", accelerator=acc("/"),
                           command=self.toggle_comment)
            em.add_command(label="Format Document", accelerator=acc("L", True),
                           command=self.format_active)
            em.add_command(label="Fix Everything", accelerator=acc("F", True),
                           command=self.fix_all_active)
            m.add_cascade(label="Edit", menu=em)

            vm = tk.Menu(m, tearoff=0)
            vm.add_command(label="Bigger Text", accelerator=acc("+"),
                           command=lambda: self.zoom(1))
            vm.add_command(label="Smaller Text", accelerator=acc("-"),
                           command=lambda: self.zoom(-1))
            vm.add_command(label="Reset Text Size", accelerator=acc("0"),
                           command=lambda: self.zoom(0))
            vm.add_separator()
            vm.add_command(label="Show/Hide Output", accelerator=acc("J"),
                           command=lambda: self.output.toggle())
            vm.add_command(label="Show/Hide Outline", accelerator=acc("B"),
                           command=self.toggle_outline)
            vm.add_command(label="Welcome Screen",
                           command=self.show_home_if_free)
            m.add_cascade(label="View", menu=vm)

            rm = tk.Menu(m, tearoff=0)
            rm.add_command(label="Run", accelerator=acc("R"),
                           command=self.run_active)
            rm.add_command(label="Debug", accelerator=acc("R", True),
                           command=lambda: self.run_active(True))
            rm.add_command(label="Stop", accelerator=acc("."),
                           command=self.stop_run)
            rm.add_separator()
            rm.add_command(label="Clear Output", accelerator=acc("K"),
                           command=lambda: self.output.clear())
            m.add_cascade(label="Run", menu=rm)

            tm = tk.Menu(m, tearoff=0)
            tm.add_checkbutton(label="Auto-check (hints, Tab fixes)",
                               accelerator=acc("A", True),
                               variable=self.autocheck_var,
                               command=self._autocheck_from_menu)
            self.lang_menu = tk.Menu(tm, tearoff=0,
                                     postcommand=self._fill_lang_menu)
            tm.add_cascade(label="Language", menu=self.lang_menu)
            tm.add_separator()
            tm.add_command(label="Database Console…",
                           command=self.show_database)
            tm.add_command(label="Language Toolchains…",
                           command=self.show_toolchains)
            tm.add_command(label="Run Self-Test", command=self.run_selftest)
            m.add_cascade(label="Tools", menu=tm)

            hm = tk.Menu(m, tearoff=0, name="help" if IS_MAC else None)
            hm.add_command(label="Keyboard Shortcuts",
                           command=self.show_shortcuts)
            if not IS_MAC:
                hm.add_command(label="About " + APP, command=self.show_about)
            m.add_cascade(label="Help", menu=hm)
            self.config(menu=m)

        def _bind_keys(self):
            mod = "Command" if IS_MAC else "Control"

            def bind(key, fn):
                self.bind_all("<%s-%s>" % (mod, key),
                              lambda e, f=fn: self._key(f))
            bind("n", self.new_file_dialog)
            bind("o", self.open_dialog)
            bind("s", self.save_active)
            bind("S", self.save_as_active)
            bind("w", self.close_active)
            bind("q", self.quit_app)
            bind("r", self.run_active)
            bind("R", lambda: self.run_active(True))
            bind("period", self.stop_run)
            bind("f", self.show_findbar)
            bind("F", self.fix_all_active)
            bind("L", self.format_active)
            bind("l", self.goto_dialog)
            bind("slash", self.toggle_comment)
            bind("j", self.output.toggle)
            bind("b", self.toggle_outline)
            bind("k", self.output.clear)
            bind("a", self.select_all)
            bind("A", self.toggle_autocheck)
            bind("equal", lambda: self.zoom(1))
            bind("plus", lambda: self.zoom(1))
            bind("minus", lambda: self.zoom(-1))
            bind("0", lambda: self.zoom(0))
            self.bind_all("<F5>", lambda e: self._key(self.run_active))

        def _key(self, fn):
            fn()
            return "break"

        def _ev(self, seq):
            w = self.focus_get()
            if w is not None:
                try:
                    w.event_generate(seq)
                except tk.TclError:
                    pass

        def _set_icon(self):
            try:
                img = tk.PhotoImage(width=32, height=32)
                img.put(THEME["bg"], to=(0, 0, 32, 32))
                for y in range(32):
                    for x in range(32):
                        if (x - 16) ** 2 + (y - 17) ** 2 <= 180:
                            img.put(THEME["accent"], (x, y))
                for y in range(9, 15):
                    for x in range(19, 25):
                        if (x - 22) ** 2 + (y - 12) ** 2 <= 7:
                            img.put("#0c110f", (x, y))
                self.iconphoto(True, img)
                self._icon_img = img
            except Exception:
                pass

        # ---- settings & recents --------------------------------------------

        def _settings_path(self):
            return os.path.join(settings_dir(), "settings.json")

        def _load_settings(self):
            try:
                with open(self._settings_path(), "r", encoding="utf-8") as f:
                    d = json.load(f)
                return d if isinstance(d, dict) else {}
            except Exception:
                return {}

        def save_settings(self):
            self.settings["autocheck"] = self.autocheck
            self.settings["font_size"] = self.mono_font.cget("size")
            try:
                self.settings["geometry"] = self.geometry()
            except tk.TclError:
                pass
            try:
                with open(self._settings_path(), "w", encoding="utf-8") as f:
                    json.dump(self.settings, f, indent=2)
            except OSError:
                pass

        def add_recent(self, path):
            r = [p for p in self.settings.get("recent", []) if p != path]
            r.insert(0, path)
            self.settings["recent"] = r[:12]

        def _fill_recent(self):
            self.recent_menu.delete(0, "end")
            recents = self.settings.get("recent", [])
            if not recents:
                self.recent_menu.add_command(label="(empty)", state="disabled")
                return
            for p in recents:
                self.recent_menu.add_command(
                    label=shorten_home(p),
                    command=lambda pp=p: self.open_path(pp))
            self.recent_menu.add_separator()
            self.recent_menu.add_command(label="Clear Menu",
                                         command=self._clear_recent)

        def _clear_recent(self):
            self.settings["recent"] = []
            if not self._active:
                self.home.refresh()

        def _fill_lang_menu(self):
            self.lang_menu.delete(0, "end")
            tab = self.active_tab()
            for lid in LANG_ORDER:
                mark = "◉ " if (tab and tab.lang == lid) else "   "
                self.lang_menu.add_command(
                    label=mark + LANGS[lid]["name"],
                    command=lambda l=lid: self.set_language(l))

        def set_language(self, lang_id):
            tab = self.active_tab()
            if tab:
                tab.set_language(lang_id)
                self.flash_status("Language: %s" % LANGS[lang_id]["name"])

        def language_menu(self):
            """Pop up a language chooser from the status bar."""
            tab = self.active_tab()
            if not tab:
                return
            menu = tk.Menu(self, tearoff=0)
            for lid in LANG_ORDER:
                mark = "◉ " if tab.lang == lid else "   "
                menu.add_command(label=mark + LANGS[lid]["name"],
                                 command=lambda l=lid: self.set_language(l))
            try:
                x = self.st_lang.winfo_rootx()
                y = self.st_lang.winfo_rooty()
                menu.tk_popup(x, y - 6)
            finally:
                menu.grab_release()

        # ---- tabs ------------------------------------------------------------

        def active_tab(self):
            return self._active

        def add_tab(self, tab):
            self.tabs.append(tab)
            self.activate(tab)

        def activate(self, tab):
            if self._active is not None and self._active is not tab:
                self._active.pack_forget()
            self.home.pack_forget()
            self._active = tab
            tab.pack(in_=self.editor_area, fill="both", expand=True)
            tab.text.focus_set()
            self.refresh_titles()
            self.update_status()
            self.update_issue_ui()
            self.refresh_outline_if_visible()
            tab.gutter.schedule()

        def show_home(self):
            if self._active is not None:
                self._active.pack_forget()
                self._active = None
            self.hide_completion()
            self.hide_hint()
            self.home.refresh()
            self.home.pack(fill="both", expand=True)
            self.refresh_titles()
            self.update_status()
            self.update_issue_ui()
            self.refresh_outline_if_visible()

        def show_home_if_free(self):
            if self._active is not None:
                self._active.pack_forget()
                self._active = None
            self.show_home()

        def refresh_titles(self):
            for w in self.tabrow.winfo_children():
                w.destroy()
            for tab in self.tabs:
                self._tab_button(tab)
            FlatButton(self.tabrow, " ＋ ", self.new_file_dialog,
                       font=self.small_font, padx=6, pady=3)\
                .pack(side="left", padx=(6, 0), pady=4)
            t = self.active_tab()
            self.title("%s — %s%s" % (APP, t.title, " •" if t.dirty else "")
                       if t else APP)

        def _tab_button(self, tab):
            active = tab is self._active
            bg = THEME["bg_active"] if active else THEME["bg_panel"]
            fg = THEME["fg"] if active else THEME["fg_dim"]
            f = tk.Frame(self.tabrow, bg=bg)
            f.pack(side="left", padx=(5, 0), pady=(5, 0))
            name = ("● " if tab.dirty else "") + tab.title
            lbl = tk.Label(f, text=name, bg=bg, fg=fg, font=self.small_font,
                           padx=8, pady=3, cursor="hand2")
            lbl.pack(side="left")
            x = tk.Label(f, text="✕", bg=bg, fg=THEME["fg_faint"],
                         font=self.small_font, padx=5, pady=3, cursor="hand2")
            x.pack(side="left")
            lbl.bind("<Button-1>", lambda e, tb=tab: self.activate(tb))
            x.bind("<Button-1>", lambda e, tb=tab: self.close_tab(tb))
            x.bind("<Enter>", lambda e, w=x: w.configure(fg=THEME["error"]))
            x.bind("<Leave>", lambda e, w=x: w.configure(fg=THEME["fg_faint"]))

        # ---- file operations ------------------------------------------------

        def new_file_dialog(self):
            LanguagePicker(self, self.new_file)

        def new_file(self, lang_id):
            sk = SKELETONS.get(lang_id, "")
            clean, spans = parse_placeholders(sk)
            tab = EditorTab(self.editor_area, self, lang=lang_id, content=clean,
                            placeholders=spans)
            self.add_tab(tab)
            self.flash_status("New %s file — %s saves it"
                              % (LANGS[lang_id]["name"],
                                 "⌘S" if IS_MAC else "Ctrl+S"))

        def open_dialog(self):
            path = filedialog.askopenfilename(
                parent=self,
                initialdir=self.settings.get("last_dir")
                or os.path.expanduser("~"))
            if path:
                self.open_path(path)

        def open_path(self, path):
            path = os.path.abspath(path)
            for tab in self.tabs:
                if tab.path == path:
                    self.activate(tab)
                    return
            try:
                with open(path, "rb") as f:
                    head = f.read(8192)
                if b"\x00" in head:
                    messagebox.showwarning(
                        APP, "That looks like a binary file.\n"
                             "GeskoIDE edits text files.", parent=self)
                    return
                if os.path.getsize(path) > 8000000:
                    if not messagebox.askyesno(
                            APP, "This file is quite large - open anyway?",
                            parent=self):
                        return
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except OSError as ex:
                messagebox.showerror(APP, "Could not open the file:\n%s" % ex,
                                     parent=self)
                return
            content = content.replace("\r\n", "\n").replace("\r", "\n")
            tab = EditorTab(self.editor_area, self, path=path, content=content)
            self.add_tab(tab)
            self.add_recent(path)
            self.settings["last_dir"] = os.path.dirname(path)

        def save_active(self):
            tab = self.active_tab()
            if not tab:
                return
            if not tab.path:
                self.save_as_active()
                return
            tab.save_to(tab.path)
            self.add_recent(tab.path)
            self.refresh_titles()
            self.update_status()
            tab.run_checks(show_hint=False)
            self.flash_status("Saved " + tab.title)

        def save_as_active(self):
            tab = self.active_tab()
            if not tab:
                return
            ext = os.path.splitext(tab.title)[1]
            path = filedialog.asksaveasfilename(
                parent=self, initialfile=tab.title,
                defaultextension=ext or "",
                initialdir=self.settings.get("last_dir")
                or os.path.expanduser("~"))
            if not path:
                return
            tab.save_to(path)
            self.add_recent(path)
            self.settings["last_dir"] = os.path.dirname(path)
            self.refresh_titles()
            self.update_status()
            tab.run_checks(show_hint=False)
            self.flash_status("Saved " + tab.title)

        def close_active(self):
            tab = self.active_tab()
            if tab:
                self.close_tab(tab)
            else:
                self.quit_app()

        def close_tab(self, tab):
            if tab.dirty:
                self.activate(tab)
                ans = messagebox.askyesnocancel(
                    APP, "Save changes to %s?" % tab.title, parent=self)
                if ans is None:
                    return False
                if ans:
                    self.save_active()
                    if tab.dirty:
                        return False
            if tab in self.tabs:
                self.tabs.remove(tab)
            if self._active is tab:
                self._active = None
                tab.destroy()
                if self.tabs:
                    self.activate(self.tabs[-1])
                else:
                    self.show_home()
            else:
                tab.destroy()
                self.refresh_titles()
            return True

        def quit_app(self):
            for tab in list(self.tabs):
                if tab.dirty:
                    self.activate(tab)
                    ans = messagebox.askyesnocancel(
                        APP, "Save changes to %s before quitting?" % tab.title,
                        parent=self)
                    if ans is None:
                        return
                    if ans:
                        self.save_active()
                        if tab.dirty:
                            return
            self.save_settings()
            if self.runner:
                self.runner.stop()
            self.destroy()

        def _mac_open_docs(self, *paths):
            for p in paths:
                if os.path.exists(p):
                    self.open_path(p)

        # ---- status, hints & issues -----------------------------------------

        def flash_status(self, msg):
            self.st_msg.config(text=msg)
            if self._flash_job:
                try:
                    self.after_cancel(self._flash_job)
                except Exception:
                    pass
            self._flash_job = self.after(
                3000, lambda: self.st_msg.config(text=""))

        def update_status(self):
            self.st_check.config(
                text="Auto-check: %s" % ("on" if self.autocheck else "off"),
                fg=THEME["accent"] if self.autocheck else THEME["fg_dim"])
            tab = self.active_tab()
            if not tab:
                self.st_pos.config(text="")
                self.st_lang.config(text="")
                self.st_indent.config(text="")
                return
            ln, col = tab.text.index("insert").split(".")
            self.st_pos.config(text="Ln %s, Col %d" % (ln, int(col) + 1))
            sp = LANGS[tab.lang]
            self.st_lang.config(text=sp["name"], fg=THEME["accent"])
            self.st_indent.config(
                text="Tab" if sp["indent_char"] == "\t"
                else "Spaces: %d" % sp["indent"])

        def update_issue_ui(self):
            for w in self.hintbar.winfo_children():
                w.destroy()
            tab = self.active_tab()
            if not tab:
                self.st_issues.config(text="")
                self.hintbar.grid_remove()
                return
            issues = tab.issues
            if not issues:
                if getattr(tab, "check_error", None):
                    self.st_issues.config(text="⚠ auto-check hiccup (see log)",
                                          fg=THEME["warn"])
                else:
                    self.st_issues.config(
                        text="✓ No problems" if self.autocheck else "",
                        fg=THEME["ok"])
                self.hintbar.grid_remove()
                return
            errs = sum(1 for i in issues if i.severity == "error")
            warns = sum(1 for i in issues if i.severity == "warn")
            infos = len(issues) - errs - warns
            bits = []
            for n, word in ((errs, "error"), (warns, "warning"), (infos, "hint")):
                if n:
                    bits.append("%d %s%s" % (n, word, "" if n == 1 else "s"))
            self.st_issues.config(text="⚠ " + " · ".join(bits),
                                  fg=THEME["error"] if errs else THEME["warn"])
            for iss in issues[:3]:
                chip = tk.Frame(self.hintbar, bg=THEME["bg_panel"])
                chip.pack(side="left", padx=(8, 0), pady=3)
                tk.Label(chip, text="●", bg=THEME["bg_panel"],
                         fg=THEME[SEV_COLOR_KEY[iss.severity]],
                         font=self.small_font).pack(side="left", padx=(4, 2))
                lbl = tk.Label(chip, text="Ln %d  %s" % (iss.line, iss.msg),
                               bg=THEME["bg_panel"], fg=THEME["fg_dim"],
                               font=self.small_font, cursor="hand2")
                lbl.pack(side="left")
                lbl.bind("<Button-1>",
                         lambda e, i=iss, tb=tab: tb.goto_issue(i))
                if iss.fix:
                    FlatButton(chip, "Fix",
                               lambda i=iss, tb=tab: tb.fix_issues([i]),
                               font=self.small_font, padx=6, pady=0)\
                        .pack(side="left", padx=(6, 2))
            if len(issues) > 3:
                tk.Label(self.hintbar, text="+%d more" % (len(issues) - 3),
                         bg=THEME["bg_panel"], fg=THEME["fg_faint"],
                         font=self.small_font).pack(side="left", padx=8)
            fixable = [i for i in issues if i.fix]
            if fixable:
                FlatButton(self.hintbar, "Fix all (%d)" % len(fixable),
                           tab.fix_all, "primary", font=self.small_font,
                           padx=8, pady=1).pack(side="right", padx=8, pady=3)
            self.hintbar.grid()

        def goto_first_issue(self):
            tab = self.active_tab()
            if tab and tab.issues:
                tab.goto_issue(tab.issues[0])

        def toggle_autocheck(self):
            self.autocheck = not self.autocheck
            self.autocheck_var.set(self.autocheck)
            self._after_autocheck_change()

        def _autocheck_from_menu(self):
            self.autocheck = bool(self.autocheck_var.get())
            self._after_autocheck_change()

        def _after_autocheck_change(self):
            if not self.autocheck:
                self.hide_hint()
                self.hide_completion()
            for tab in self.tabs:
                tab.run_checks(show_hint=False)
            self.update_status()
            self.update_issue_ui()
            self.flash_status("Auto-check %s"
                              % ("on" if self.autocheck else "off"))

        def select_all(self):
            tab = self.active_tab()
            if tab:
                tab.text.tag_add("sel", "1.0", "end-1c")

        def toggle_comment(self):
            tab = self.active_tab()
            if tab:
                tab.toggle_comment()

        def fix_all_active(self):
            self.deep_fix_active()

        def deep_fix_active(self):
            """Run the GeckoFix engine on the active buffer (background)."""
            tab = self.active_tab()
            if not tab:
                self.flash_status("Open a file first")
                return
            if getattr(self, "_fixing", False):
                self.flash_status("Already fixing…")
                return
            self._fixing = True
            self.flash_status("Deep-fixing… (compilers may run)")
            txt = tab.get_text()
            lang = tab.lang
            box = _queue.Queue()

            def work():
                try:
                    box.put(fix_everything(txt, lang))
                except Exception as ex:
                    _log_error("fix_everything", ex)
                    box.put((txt, ["fix engine error: %r" % ex], []))
            threading.Thread(target=work, daemon=True).start()

            def poll():
                try:
                    new_text, log, remaining = box.get_nowait()
                except _queue.Empty:
                    self.after(80, poll)
                    return
                self._fixing = False
                if not tab.winfo_exists():
                    return
                changed = new_text != txt
                if changed:
                    if tab.get_text() != txt:
                        self.flash_status("Buffer changed while fixing - "
                                          "run Fix Everything again")
                        return
                    tab.replace_buffer(new_text)
                    tab.issues = remaining
                    tab._render_issues(remaining)
                    self.update_issue_ui()
                errs = sum(1 for i in remaining if i.severity == "error")
                self.output.begin_static("Fix report · %s" % tab.title)
                if log:
                    for line in log:
                        self.output.append("out", "  ✓ %s\n" % line)
                else:
                    self.output.append("info", "  Nothing needed fixing.\n")
                if errs:
                    self.output.append("err",
                                       "  %d error%s left (see the hint bar) - "
                                       "some problems need a human decision.\n"
                                       % (errs, "" if errs == 1 else "s"))
                else:
                    self.output.append("ok", "  No errors remain.\n")
                self.flash_status(
                    "Fixed %d thing%s · %d error%s left"
                    % (len(log), "" if len(log) == 1 else "s",
                       errs, "" if errs == 1 else "s"))
            poll()

        def format_active(self):
            """Format Document: real formatter if installed, else built-in."""
            tab = self.active_tab()
            if not tab:
                return
            txt = tab.get_text()
            try:
                new_text, tool = format_source(txt, tab.lang)
            except Exception as ex:
                _log_error("format_source", ex)
                return
            if new_text != txt:
                tab.replace_buffer(new_text)
                self.flash_status("Formatted with %s" % tool)
            else:
                self.flash_status("Already tidy")

        def zoom(self, d):
            s = self.mono_font.cget("size")
            s = max(9, min(30, s + d)) if d else 13
            for f in (self.mono_font, self.mono_bold, self.mono_italic):
                f.configure(size=s)
            for tab in self.tabs:
                tab.apply_font()
                tab.gutter.schedule()

        # ---- popups -----------------------------------------------------------

        def _place_popup(self, pop, tab, dy=4):
            t = tab.text
            bbox = t.bbox("insert")
            if not bbox:
                t.update_idletasks()
                bbox = t.bbox("insert") or (12, 12, 8, 16)
            x = t.winfo_rootx() + bbox[0]
            y = t.winfo_rooty() + bbox[1] + bbox[3] + dy
            pop.update_idletasks()
            sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
            w, h = pop.winfo_reqwidth(), pop.winfo_reqheight()
            if x + w > sw:
                x = max(0, sw - w - 8)
            if y + h > sh:
                y = t.winfo_rooty() + bbox[1] - h - 4
            pop.geometry("+%d+%d" % (x, y))
            pop.lift()

        def show_completion(self, tab, prefix, words):
            self.hide_completion()
            self._completion_ctx = (tab, prefix)
            self.completion_popup = CompletionPopup(self, self, words,
                                                    self._completion_accept)
            self._place_popup(self.completion_popup, tab)

        def refill_completion(self, prefix, words):
            pop = self.completion_popup
            if pop and pop.winfo_exists() and self._completion_ctx:
                tab = self._completion_ctx[0]
                self._completion_ctx = (tab, prefix)
                pop.fill(words)
                self._place_popup(pop, tab)

        def accept_completion(self):
            pop = self.completion_popup
            if pop and pop.winfo_exists():
                pop.accept()

        def _completion_accept(self, word):
            if not self._completion_ctx:
                return
            tab, prefix = self._completion_ctx
            t = tab.text
            t.delete("insert-%dc" % len(prefix), "insert")
            t.insert("insert", word)
            self.hide_completion()

        def hide_completion(self):
            if self.completion_popup:
                try:
                    self.completion_popup.destroy()
                except tk.TclError:
                    pass
            self.completion_popup = None
            self._completion_ctx = None

        def show_hint(self, tab, issue):
            key = (issue.line, issue.msg)
            if (self._hint_key == key and self.hint_popup
                    and self.hint_popup.winfo_exists()):
                return
            self.hide_hint()
            self._hint_key = key

            def do_fix():
                tab.fix_issues([issue])
                self.hide_hint()
            self.hint_popup = HintPopup(self, self, issue,
                                        do_fix if issue.fix else None)
            self._place_popup(self.hint_popup, tab, dy=6)
            self.after(9000, lambda p=self.hint_popup: self._expire_hint(p))

        def _expire_hint(self, p):
            if self.hint_popup is p:
                self.hide_hint()

        def hide_hint(self):
            if self.hint_popup:
                try:
                    self.hint_popup.destroy()
                except tk.TclError:
                    pass
            self.hint_popup = None
            self._hint_key = None

        def show_findbar(self):
            if self.active_tab():
                self.findbar.show()

        def hide_findbar(self):
            self.findbar.hide()

        def toggle_outline(self):
            if self.active_tab():
                self.outline.toggle()
            else:
                self.flash_status("Open a file first")

        def refresh_outline_if_visible(self):
            if getattr(self, "outline", None) and self.outline.visible:
                self.outline.refresh()

        # ---- running ----------------------------------------------------------

        def run_active(self, debug=False):
            tab = self.active_tab()
            if not tab:
                self.flash_status("Create or open a file first")
                return
            self.stop_run()
            self.hide_completion()
            self.hide_hint()
            if tab.path:
                tab.save_to(tab.path)
                self.refresh_titles()
                path = tab.path
            else:
                d = os.path.join(settings_dir(), "scratch")
                try:
                    os.makedirs(d, exist_ok=True)
                except OSError:
                    d = tempfile.gettempdir()
                path = os.path.join(d, tab.title)
                txt = tab.get_text()
                with open(path, "w", encoding="utf-8") as f:
                    f.write(txt if (not txt or txt.endswith("\n"))
                            else txt + "\n")
            if tab.lang == "json":
                self.output.begin_static("Validate " + tab.title)
                try:
                    obj = json.loads(tab.get_text() or "null")
                    pretty = json.dumps(obj, indent=2, ensure_ascii=False)
                    self.output.append("out", pretty[:20000] + "\n")
                    self.output.append("ok", "Valid JSON\n")
                except json.JSONDecodeError as ex:
                    self.output.append("err", "Invalid JSON: %s\n" % ex)
                return
            if tab.lang == "markdown":
                html = markdown_to_html(tab.get_text(), tab.title)
                out = os.path.join(tempfile.gettempdir(),
                                   "geskoide-preview.html")
                with open(out, "w", encoding="utf-8") as f:
                    f.write(html)
                webbrowser.open("file://" + out)
                self.output.begin_static("Preview " + tab.title)
                self.output.append("info", "Preview opened in your browser "
                                           "(rendered locally, offline).\n")
                return
            kind, val = build_steps(tab.lang, path, debug=debug,
                                    breakpoints=sorted(tab.breakpoints))
            if kind == "info":
                self.output.begin_static("Run " + tab.title)
                self.output.append("info", val + "\n")
                return
            if kind == "open":
                webbrowser.open("file://" + val)
                self.output.begin_static("Preview " + tab.title)
                self.output.append("info", "Opened in your default browser "
                                           "(local file, no internet).\n")
                return
            self.runner = StepRunner(val, cwd=os.path.dirname(path) or None)
            self.output.begin_run(tab.title, debug)
            self.output.set_debug_buttons(
                debug and tab.lang in ("python", "c", "cpp", "rust", "java"))
            self.runner.start()
            self.output.poll(self.runner)

        def stop_run(self):
            if self.runner:
                self.runner.stop()

        def run_selftest(self):
            self.stop_run()
            me = os.path.abspath(__file__)
            self.runner = StepRunner(
                [{"argv": [sys.executable or "python3", me, "--selftest"],
                  "label": "GeskoIDE self-test"}])
            self.output.begin_run("self-test", False)
            self.runner.start()
            self.output.poll(self.runner)

        # ---- dialogs ----------------------------------------------------------

        def _center_child(self, win, w, h):
            try:
                self.update_idletasks()
                x = self.winfo_rootx() + max(0, (self.winfo_width() - w) // 2)
                y = self.winfo_rooty() + max(0, (self.winfo_height() - h) // 3)
                win.geometry("%dx%d+%d+%d" % (w, h, x, y))
            except tk.TclError:
                pass

        def goto_dialog(self):
            tab = self.active_tab()
            if not tab:
                return
            win = tk.Toplevel(self)
            win.title("Go to Line")
            win.configure(bg=THEME["bg_panel"], padx=16, pady=14)
            win.transient(self)
            win.resizable(False, False)
            tk.Label(win, text="Jump to line:", bg=THEME["bg_panel"],
                     fg=THEME["fg"], font=self.ui_font).pack(anchor="w")
            e = tk.Entry(win, bg=THEME["bg_input"], fg=THEME["fg"],
                         insertbackground=THEME["caret"], bd=0,
                         highlightthickness=1, width=12,
                         highlightbackground=THEME["border"],
                         highlightcolor=THEME["accent_dark"],
                         font=self.mono_font)
            e.pack(pady=9, fill="x")

            def go(ev=None):
                raw = e.get().strip()
                win.destroy()
                if raw.isdigit():
                    tab.goto_line(int(raw))
            e.bind("<Return>", go)
            e.bind("<Escape>", lambda ev: win.destroy())
            FlatButton(win, "Go", go, "primary",
                       font=self.small_font).pack(anchor="e")
            self._center_child(win, 250, 128)
            e.focus_set()
            try:
                win.grab_set()
            except tk.TclError:
                pass

        def show_database(self):
            """A real SQLite workbench - the database engine ships inside
            Python's standard library, so this needs nothing installed."""
            import sqlite3
            win = tk.Toplevel(self)
            win.title("Database Console (SQLite, built in)")
            win.configure(bg=THEME["bg_panel"], padx=12, pady=10)
            win.transient(self)
            state = {"db": sqlite3.connect(":memory:"), "path": ":memory:"}

            top = tk.Frame(win, bg=THEME["bg_panel"])
            top.pack(fill="x")
            path_lbl = tk.Label(top, text="db: :memory:", bg=THEME["bg_panel"],
                                fg=THEME["fg_dim"], font=self.small_font)
            path_lbl.pack(side="left", padx=(2, 8))

            sql = tk.Text(win, height=5, bg=THEME["bg_input"], fg=THEME["fg"],
                          insertbackground=THEME["caret"], bd=0,
                          highlightthickness=1, font=self.mono_font,
                          highlightbackground=THEME["border"],
                          highlightcolor=THEME["accent_dark"])
            sql.pack(fill="x", pady=6)
            sql.insert("1.0", "select sqlite_version();")

            outbox = tk.Text(win, height=16, width=86, bg="#0a100d",
                             fg=THEME["fg"], bd=0, highlightthickness=0,
                             font=self.mono_font, state="disabled")
            outbox.pack(fill="both", expand=True)
            outbox.tag_configure("err", foreground=THEME["error"])
            outbox.tag_configure("dim", foreground=THEME["fg_dim"])

            def put(s, tag="out"):
                outbox.configure(state="normal")
                outbox.insert("end", s, (tag,) if tag != "out" else ())
                outbox.see("end")
                outbox.configure(state="disabled")

            def run_sql(ev=None):
                cur = state["db"].cursor()
                script = sql.get("1.0", "end-1c")
                put("\n> %s\n" % " ".join(script.split())[:96], "dim")
                try:
                    cur.execute(script)
                except sqlite3.Error:
                    try:
                        cur.executescript(script)
                        state["db"].commit()
                        put("ok\n")
                        return
                    except sqlite3.Error as e2:
                        put("SQL error: %s\n" % e2, "err")
                        return
                if cur.description:
                    cols = [d[0] for d in cur.description]
                    rows = cur.fetchmany(500)
                    put(" | ".join(cols) + "\n")
                    put("-" * min(84, max(10, len(" | ".join(cols)))) + "\n",
                        "dim")
                    for r in rows:
                        put(" | ".join(str(v) for v in r) + "\n")
                    put("(%d row%s)\n" % (len(rows),
                                          "" if len(rows) == 1 else "s"),
                        "dim")
                else:
                    state["db"].commit()
                    put("ok (%d row%s affected)\n"
                        % (cur.rowcount, "" if cur.rowcount == 1 else "s"))

            def open_db():
                p = filedialog.askopenfilename(
                    parent=win, filetypes=[("SQLite", "*.db *.sqlite *.sqlite3"),
                                           ("All files", "*")])
                if p:
                    try:
                        state["db"].close()
                        state["db"] = sqlite3.connect(p)
                        state["path"] = p
                        path_lbl.config(text="db: " + shorten_home(p))
                        put("opened %s\n" % shorten_home(p), "dim")
                    except sqlite3.Error as e:
                        put("could not open: %s\n" % e, "err")

            def save_db():
                p = filedialog.asksaveasfilename(
                    parent=win, defaultextension=".db")
                if p:
                    try:
                        dst = sqlite3.connect(p)
                        state["db"].backup(dst)
                        dst.close()
                        put("saved to %s\n" % shorten_home(p), "dim")
                    except (sqlite3.Error, AttributeError) as e:
                        put("could not save: %s\n" % e, "err")

            def tables():
                sql.delete("1.0", "end")
                sql.insert("1.0", "select name, type from sqlite_master "
                                  "order by type, name;")
                run_sql()

            FlatButton(top, "Run (⌘⏎)", run_sql, "primary",
                       font=self.small_font, padx=9, pady=2)\
                .pack(side="right", padx=2)
            for label, fn in (("Tables", tables), ("Save As…", save_db),
                              ("Open…", open_db)):
                FlatButton(top, label, fn, font=self.small_font,
                           padx=8, pady=2).pack(side="right", padx=2)
            sql.bind("<Command-Return>" if IS_MAC else "<Control-Return>",
                     lambda e: (run_sql(), "break")[1])
            win.bind("<Escape>", lambda e: win.destroy())
            win.protocol("WM_DELETE_WINDOW",
                         lambda: (state["db"].close(), win.destroy()))
            self._center_child(win, 720, 560)
            sql.focus_set()

        def show_toolchains(self):
            """Show which languages can Run / Debug with the tools present."""
            win = tk.Toplevel(self)
            win.title("Language Toolchains")
            win.configure(bg=THEME["bg_panel"], padx=18, pady=14)
            win.transient(self)
            tk.Label(win, text="What can run on this computer, right now",
                     bg=THEME["bg_panel"], fg=THEME["fg"],
                     font=self.ui_font).pack(anchor="w")
            tk.Label(win, text="GeskoIDE uses the tools already installed — "
                               "nothing is downloaded, no internet is used.",
                     bg=THEME["bg_panel"], fg=THEME["fg_dim"],
                     font=self.small_font).pack(anchor="w", pady=(0, 8))
            wrap = tk.Frame(win, bg=THEME["bg_panel"])
            wrap.pack(fill="both", expand=True)
            canvas = tk.Canvas(wrap, bg=THEME["bg_panel"], highlightthickness=0,
                               width=600, height=420)
            sb = tk.Scrollbar(wrap, orient="vertical", command=canvas.yview)
            inner = tk.Frame(canvas, bg=THEME["bg_panel"])
            canvas.configure(yscrollcommand=sb.set)
            canvas.pack(side="left", fill="both", expand=True)
            sb.pack(side="right", fill="y")
            cw = canvas.create_window((0, 0), window=inner, anchor="nw")
            inner.bind("<Configure>", lambda e: canvas.configure(
                scrollregion=canvas.bbox("all")))
            canvas.bind("<Configure>",
                        lambda e: canvas.itemconfigure(cw, width=e.width))
            hdr = tk.Frame(inner, bg=THEME["bg_panel"])
            hdr.pack(fill="x", pady=(0, 2))
            for txt, w in (("Language", 15), ("Run", 6), ("Debug", 7),
                           ("Tool / how to enable", 30)):
                tk.Label(hdr, text=txt, width=w, anchor="w",
                         bg=THEME["bg_panel"], fg=THEME["fg_faint"],
                         font=self.small_font).pack(side="left")
            for lid in LANG_ORDER:
                kind, val = build_steps(lid, "x" + LANGS[lid]["exts"][0])
                dbg_kind, _ = build_steps(lid, "x" + LANGS[lid]["exts"][0],
                                          debug=True)
                runnable = kind in ("steps", "open")
                if lid in ("css", "yaml", "text"):
                    run_mark, note = "—", "editing only"
                elif lid == "json":
                    run_mark, note, runnable = "✓", "validate (built in)", True
                elif lid == "markdown":
                    run_mark, note, runnable = "✓", "HTML preview (built in)", \
                        True
                elif runnable:
                    tool = ""
                    if kind == "steps":
                        tool = os.path.basename(val[0]["argv"][0])
                    run_mark, note = "✓", (tool or "browser preview")
                else:
                    run_mark = "✗"
                    note = re.split(r"[.\n]", val)[0] if isinstance(val, str) \
                        else "needs its tool"
                dbg_mark = "✓" if (kind == "steps"
                                   and dbg_kind == "steps") else "—"
                row = tk.Frame(inner, bg=THEME["bg_panel"])
                row.pack(fill="x")
                tk.Label(row, text=LANGS[lid]["name"], width=15, anchor="w",
                         bg=THEME["bg_panel"], fg=THEME["fg"],
                         font=self.small_font).pack(side="left")
                tk.Label(row, text=run_mark, width=6, anchor="w",
                         bg=THEME["bg_panel"],
                         fg=THEME["ok"] if run_mark == "✓" else THEME["fg_faint"],
                         font=self.small_font).pack(side="left")
                tk.Label(row, text=dbg_mark, width=7, anchor="w",
                         bg=THEME["bg_panel"],
                         fg=THEME["ok"] if dbg_mark == "✓" else THEME["fg_faint"],
                         font=self.small_font).pack(side="left")
                tk.Label(row, text=note[:44], anchor="w", bg=THEME["bg_panel"],
                         fg=THEME["fg_dim"], font=self.small_font).pack(
                    side="left", fill="x")
            FlatButton(win, "Close", win.destroy, "primary",
                       font=self.small_font).pack(anchor="e", pady=(10, 0))
            win.bind("<Escape>", lambda e: win.destroy())
            self._center_child(win, 640, 560)

        def show_shortcuts(self):
            win = tk.Toplevel(self)
            win.title("Keyboard Shortcuts")
            win.configure(bg=THEME["bg_panel"], padx=20, pady=16)
            win.transient(self)
            win.resizable(False, False)
            mod = "⌘" if IS_MAC else "Ctrl+"
            rows = [
                ("New file", mod + "N"),
                ("Open file", mod + "O"),
                ("Save  /  Save As", "%sS  /  ⇧%sS" % (mod, mod)),
                ("Close tab", mod + "W"),
                ("Run  /  Debug  /  Stop", "%sR  /  ⇧%sR  /  %s." % (mod, mod, mod)),
                ("Complete · fix · next placeholder", "Tab"),
                ("Un-indent", "⇧Tab"),
                ("Find & replace", mod + "F"),
                ("Fix all issues", "⇧" + mod + "F"),
                ("Show/hide outline", mod + "B"),
                ("Go to line", mod + "L"),
                ("Toggle comment", mod + "/"),
                ("Show/hide output", mod + "J"),
                ("Clear output", mod + "K"),
                ("Bigger / smaller text", "%s+  /  %s-" % (mod, mod)),
                ("Auto-check on/off", "⇧" + mod + "A"),
                ("Dismiss popups / placeholders", "Esc"),
            ]
            for a, b in rows:
                r = tk.Frame(win, bg=THEME["bg_panel"])
                r.pack(fill="x", pady=1)
                tk.Label(r, text=b, width=16, anchor="w", bg=THEME["bg_panel"],
                         fg=THEME["accent"], font=self.small_font)\
                    .pack(side="left")
                tk.Label(r, text=a, anchor="w", bg=THEME["bg_panel"],
                         fg=THEME["fg"], font=self.small_font)\
                    .pack(side="left")
            FlatButton(win, "Close", win.destroy,
                       font=self.small_font).pack(anchor="e", pady=(12, 0))
            win.bind("<Escape>", lambda e: win.destroy())
            self._center_child(win, 430, 470)

        def show_about(self):
            win = tk.Toplevel(self)
            win.title("About " + APP)
            win.configure(bg=THEME["bg"], padx=24, pady=18)
            win.transient(self)
            win.resizable(False, False)
            tk.Label(win, text=APP, bg=THEME["bg"], fg=THEME["fg"],
                     font=self.ui_big).pack()
            for line in ("Version %s" % VERSION,
                         "A fast, friendly code editor in a single file.",
                         "",
                         "100% offline: no accounts, no APIs, no telemetry.",
                         "Runs code with the tools already on this computer.",
                         "The “Gecko Dark” theme is original to GeskoIDE.",
                         "",
                         "Apache License 2.0"):
                tk.Label(win, text=line, bg=THEME["bg"],
                         fg=THEME["fg_dim"] if line else THEME["bg"],
                         font=self.small_font).pack()
            FlatButton(win, "Nice", win.destroy, "primary",
                       font=self.small_font).pack(pady=(12, 0))
            win.bind("<Escape>", lambda e: win.destroy())
            self._center_child(win, 380, 300)

    class LanguagePicker(tk.Toplevel):
        """'New File' dialog: pick a language, get a friendly skeleton."""

        def __init__(self, app, callback):
            super().__init__(app)
            self.app = app
            self.callback = callback
            self.items = []
            self.title("New File")
            self.configure(bg=THEME["bg_panel"], padx=16, pady=14)
            self.transient(app)
            self.resizable(False, False)
            tk.Label(self, text="What are you writing today?",
                     bg=THEME["bg_panel"], fg=THEME["fg"],
                     font=app.ui_font).pack(anchor="w")
            self.entry = tk.Entry(self, bg=THEME["bg_input"], fg=THEME["fg"],
                                  insertbackground=THEME["caret"], bd=0,
                                  highlightthickness=1, width=30,
                                  highlightbackground=THEME["border"],
                                  highlightcolor=THEME["accent_dark"],
                                  font=app.ui_font)
            self.entry.pack(fill="x", pady=(9, 7))
            self.lb = tk.Listbox(self, bg=THEME["bg_input"], fg=THEME["fg"],
                                 selectbackground=THEME["accent_dark"],
                                 selectforeground="#eafff2",
                                 highlightthickness=0, bd=0,
                                 activestyle="none", font=app.ui_font,
                                 height=13)
            self.lb.pack(fill="both", expand=True)
            tk.Label(self, text="New files start from a clean skeleton —\n"
                                "placeholders selected, Tab hops to the next one.",
                     bg=THEME["bg_panel"], fg=THEME["fg_faint"],
                     font=app.small_font, justify="left")\
                .pack(anchor="w", pady=(8, 0))
            self.entry.bind("<KeyRelease>", self._filter)
            self.entry.bind("<Return>", self._choose)
            self.entry.bind("<Escape>", lambda e: self.destroy())
            self.entry.bind("<Down>", lambda e: self._move(1))
            self.entry.bind("<Up>", lambda e: self._move(-1))
            self.lb.bind("<Double-Button-1>", self._choose)
            self.lb.bind("<Return>", self._choose)
            self.lb.bind("<Escape>", lambda e: self.destroy())
            self._filter()
            app._center_child(self, 360, 430)
            self.entry.focus_set()
            try:
                self.grab_set()
            except tk.TclError:
                pass

        def _filter(self, ev=None):
            if ev and ev.keysym in ("Return", "Up", "Down", "Escape"):
                return
            q = self.entry.get().strip().lower()
            self.items = []
            self.lb.delete(0, "end")
            for lid in LANG_ORDER:
                nm = LANGS[lid]["name"]
                if not q or q in nm.lower() or q in lid:
                    self.items.append(lid)
                    exts = LANGS[lid]["exts"]
                    self.lb.insert("end", "  %s   %s"
                                   % (nm, exts[0] if exts else ""))
            if self.items:
                self.lb.selection_set(0)

        def _move(self, d):
            cur = self.lb.curselection()
            i = max(0, min(self.lb.size() - 1, (cur[0] if cur else 0) + d))
            self.lb.selection_clear(0, "end")
            self.lb.selection_set(i)
            self.lb.see(i)
            return "break"

        def _choose(self, ev=None):
            cur = self.lb.curselection()
            if not cur or not self.items:
                self.destroy()
                return
            lid = self.items[cur[0]]
            self.destroy()
            self.callback(lid)


def shorten_home(p):
    home = os.path.expanduser("~")
    return "~" + p[len(home):] if p.startswith(home) else p


# --------------------------------------------------------------------------
# Self-test (runs without a display: pure logic + a real subprocess).
# --------------------------------------------------------------------------

def selftest():
    print("%s %s self-test (python %s)" % (APP, VERSION,
                                           sys.version.split()[0]))
    failures = []
    total = [0]

    def run(name, fn):
        total[0] += 1
        try:
            fn()
            print("  ok   %s" % name)
        except AssertionError as ex:
            failures.append(name)
            print("  FAIL %s%s" % (name, (" - %s" % ex) if str(ex) else ""))
        except Exception as ex:  # noqa
            failures.append(name)
            print("  FAIL %s - %r" % (name, ex))

    def t_polyglot():
        with open(os.path.abspath(__file__), "r", encoding="utf-8") as f:
            first = f.readline()
        assert first.startswith("#!/bin/sh"), first

    def t_lexers():
        for lid in LANGS:
            toks = tokenize("test 123 abc", lid)
            assert toks, lid

    def t_python_tokens():
        src = 'def foo(x):\n    return x + 1  # done\ns = "hi"\n'
        toks = tokenize(src, "python")
        types = {src[s:e]: tt for s, e, tt in toks}
        assert types["def"] == "keyword"
        assert types["foo"] == "func"
        assert types['"hi"'] == "string"
        assert types["# done"] == "comment"
        assert types["1"] == "number"
        assert types["return"] == "keyword"

    def t_every_word_colored():
        src = "alpha = beta(gamma) + Delta # words\n"
        toks = tokenize(src, "python")
        for m in WORD_RE.finditer(src):
            assert any(s <= m.start() and m.end() <= e
                       for s, e, _ in toks), m.group(0)

    def t_rainbow():
        src = "f([x])"
        toks = tokenize(src, "python")
        retype, unclosed, stray, _ = scan_brackets(src, toks)
        assert not unclosed and not stray
        depths = sorted(set(retype.values()))
        assert depths == ["brk0", "brk1"], depths

    def t_lineindex():
        li = LineIndex("ab\ncd\n")
        assert li.line_col(0) == (1, 0)
        assert li.line_col(3) == (2, 0)
        assert li.tk(4) == "2.1"

    def t_detect():
        assert detect_language("x.py") == "python"
        assert detect_language("x.command") == "shell"
        assert detect_language(None, "#!/usr/bin/env node") == "javascript"
        assert detect_language("x.geskoext", '{"a": 1}') == "json"

    def t_outline_items():
        py = "class App:\n    def run(self):\n        pass\n\ndef main():\n    pass\n"
        got = outline_items(py, "python")
        assert [(i.line, i.kind, i.name) for i in got] == [
            (1, "class", "App"), (2, "def", "run"), (5, "def", "main")
        ], got
        md = outline_items("# Title\n\n## Part\n", "markdown")
        assert [i.name for i in md] == ["Title", "Part"], md

    def t_missing_colon():
        issues = check_source("if x\n", "python")
        colon = [i for i in issues if i.fix and i.fix[0] == "colon"]
        assert colon, issues
        fixed = fixed_line_text("if x", colon[0], LANGS["python"])
        assert fixed == "if x:", fixed

    def t_no_false_colon():
        for src in ("if x: y()\n", "x = {1: 2}\n", "for i in r:  # c\n    pass\n",
                    "def f(\n    a,\n):\n    pass\n"):
            issues = check_source(src, "python")
            assert not any(i.fix and i.fix[0] == "colon" for i in issues), src

    def t_unclosed_paren():
        issues = check_source('print("hi"\n', "python")
        close = [i for i in issues if i.fix and i.fix[0] == "close_line"]
        assert close, issues
        fixed = fixed_line_text('print("hi"', close[0], LANGS["python"])
        assert fixed == 'print("hi")', fixed

    def t_unclosed_string():
        issues = check_source('x = "abc\n', "python")
        cs = [i for i in issues if i.fix and i.fix[0] == "close_string"]
        assert cs, issues
        fixed = fixed_line_text('x = "abc', cs[0], LANGS["python"])
        assert fixed == 'x = "abc"', fixed

    def t_triple_unclosed():
        issues = check_source('"""doc\nmore\n', "python")
        assert any(i.fix and i.fix[0] == "append_eof" for i in issues), issues

    def t_stray_close():
        issues = check_source("foo)\n", "python")
        assert any("Unexpected" in i.msg for i in issues), issues

    def t_print_py2():
        issues = check_source("print x\n", "python")
        pc = [i for i in issues if i.fix and i.fix[0] == "print_call"]
        assert pc, issues
        fixed = fixed_line_text("print x", pc[0], LANGS["python"])
        assert fixed == "print(x)", fixed
        # A string argument must still be detected (regression: the string
        # was being masked to blanks before the check could see it).
        s_issues = check_source('print "hi"\n', "python")
        sp_ = [i for i in s_issues if i.fix and i.fix[0] == "print_call"]
        assert sp_, s_issues
        assert fixed_line_text('print "hi"', sp_[0],
                               LANGS["python"]) == 'print("hi")'
        # Valid Python 3 must NOT be flagged.
        for good in ('print("hi")\n', "print()\n", "print = 5\n"):
            g = check_source(good, "python")
            assert not any(i.fix and i.fix[0] == "print_call" for i in g), good

    def t_eq_cond():
        src = "if (a = b) {\n}\n"
        issues = check_source(src, "c")
        eq = [i for i in issues if i.fix and i.fix[0] == "eq_cond"]
        assert eq, issues
        fixed = fixed_line_text("if (a = b) {", eq[0], LANGS["c"])
        assert fixed == "if (a == b) {", fixed

    def t_semicolon():
        src = "int main(void) {\n    int x = 1\n    return 0;\n}\n"
        issues = check_source(src, "c")
        semi = [i for i in issues if i.fix and i.fix[0] == "semicolon"]
        assert semi and semi[0].line == 2, issues
        fixed = fixed_line_text("    int x = 1", semi[0], LANGS["c"])
        assert fixed == "    int x = 1;", fixed

    def t_json_check():
        issues = check_source('{"a": 1,}', "json")
        assert any(i.severity == "error" for i in issues), issues
        assert not check_source('{"a": 1}', "json")

    def t_java_rename():
        issues = check_source("public class Bar {\n}\n", "java", "Foo.java")
        rn = [i for i in issues if i.fix and i.fix[0] == "rename_class"]
        assert rn and rn[0].fix[1] == "Foo", issues

    def t_compile_hint():
        issues = check_source("def f(:\n", "python")
        assert any(i.severity == "error" for i in issues), issues

    def t_py_undefined():
        m = [i.msg for i in check_source("import os\nprint(oss)\n", "python")]
        assert any("'oss' is not defined" in x for x in m), m
        assert any("'os' is imported but never used" in x for x in m), m

    def t_py_no_false_positives():
        # A spread of valid constructs must produce zero name/import warnings.
        valid = [
            "def f(a, b=1):\n    return a + b\n",
            "xs = [i for i in range(3)]\nprint(xs)\n",
            "class A:\n    def __init__(s):\n        s.x = 1\n",
            "try:\n    pass\nexcept ValueError as e:\n    print(e)\n",
            "with open('f') as fh:\n    print(fh)\n",
            "if (z := 5) > 1:\n    print(z)\n",
            "for k, v in {}.items():\n    print(k, v)\n",
            "from os import *\nprint(getcwd())\n",   # star import -> skip
            "g = lambda q: q + 1\nprint(g(2))\n",
        ]
        for s in valid:
            bad = [i.msg for i in check_source(s, "python")
                   if "not defined" in i.msg or "never used" in i.msg]
            assert not bad, (s, bad)

    def t_parse_diagnostics():
        # clang / gcc / gofmt / luac style
        d = parse_diagnostics("gcc", "t.c:3:14: error: expected ';' after\n"
                                     "t.c:5:2: warning: unused variable 'x'\n"
                                     "t.c:1:1: note: ignore me\n")
        assert (3, 13, "error") == d[0][:3], d
        assert d[0][4] == ("semicolon", None), d
        assert d[1][2] == "warn" and len(d) == 2, d
        # node --check
        dn = parse_diagnostics("node", "/x/a.js:2\n\nSyntaxError: bad thing\n")
        assert dn and dn[0][0] == 2 and "SyntaxError" in dn[0][3], dn
        # bash -n
        db = parse_diagnostics("bash", "a.sh: line 4: syntax error: eof\n")
        assert db and db[0][0] == 4, db
        # ruby / perl / php / tsc
        assert parse_diagnostics("ruby", "a.rb:3: syntax error (SyntaxError)\n")[0][0] == 3
        assert parse_diagnostics("perl", "boom at a.pl line 7, near x\n")[0][0] == 7
        assert parse_diagnostics(
            "php", "PHP Parse error:  syntax error, x in a.php on line 9\n")[0][0] == 9
        assert parse_diagnostics(
            "tsc", "a.ts(2,5): error TS2322: nope\n")[0][:2] == (2, 4)

    def t_linter_registry():
        # Every registered linter builds a sane argv and points at real langs.
        for lang, spec in EXTERNAL_LINTERS.items():
            assert lang in LANGS, lang
            argv = spec["args"](spec["tools"][0], "/tmp/x")
            assert isinstance(argv, list) and argv[0] == spec["tools"][0], lang
        assert _java_stem("public class Foo {}") == "Foo.java"
        assert _java_stem("int x;") == "Main.java"

    def t_split_comment():
        code, comment = split_code_comment('x = "#no"  # yes', "#")
        assert code == 'x = "#no"  ' and comment == "# yes", (code, comment)

    # ---- GeckoFix deep repair engine ------------------------------------

    def t_apply_edits():
        out = apply_text_edits("int x = 1\nint y = 2\n",
                               [(1, 10, 1, 10, ";"), (2, 10, 2, 10, ";")])
        assert out == "int x = 1;\nint y = 2;\n", repr(out)
        out2 = apply_text_edits("vectr\n", [(1, 1, 1, 6, "vector")])
        assert out2 == "vector\n", repr(out2)

    def t_unicode_fix():
        src = 'x = “hi”\ns = "keep “this” inside"\n'
        out = normalize_unicode_punct(src, "python")
        assert 'x = "hi"' in out, repr(out)
        assert "keep “this” inside" in out, repr(out)  # valid string untouched

    def t_fixit_parse():
        m = _FIXIT_RE.match('fix-it:"a.c":{3:18-3:18}:";"')
        assert m and m.group(2) == "3" and m.group(6) == ";", m

    def t_py_syntax_repairs():
        cases = [
            ("[1 2]\n", "forgot a comma", lambda o: "[1, 2]" in o),
            ("if x = 1:\n    pass\n", "== fix", lambda o: "x == 1" in o),
            ("def f():\nreturn 1\n", "indent block",
             lambda o: "\n    return 1" in o),
            ("x = 1\n    y = 2\n", "unexpected indent",
             lambda o: "\ny = 2" in o),
            ('s = "abc\n', "close string", lambda o: '"abc"' in o),
        ]
        for src, label, good in cases:
            out, notes = py_syntax_fix_round(src)
            assert notes and good(out), (label, out, notes)

    def t_py_semantic_repairs():
        out, n = py_semantic_fix_round("import math\nprint(maths.pi)\n")
        assert "math.pi" in out and "maths" not in out, out
        out2, n2 = py_semantic_fix_round("x = math.sqrt(2)\nprint(x)\n")
        assert out2.startswith("import math\n"), out2
        out3, n3 = py_semantic_fix_round("import os\nprint(1)\n")
        assert "import os" not in out3, out3

    def t_fix_everything_python():
        nasty = ('import maths\n\ndef average(nums)\n    total = 0\n'
                 '    for n in nums\n        total += n\n'
                 '    print "avg:", total\n    return total / len(nums\n\n'
                 'def top(items):\n        best = max(items)\n'
                 '    return best\n\nx = average([1 2, 3])\ny = “done”\n')
        out, log, remaining = fix_everything(nasty, "python")
        ast.parse(out)  # must compile clean
        assert 'print("avg:", total)' in out, out
        assert "[1, 2, 3]" in out and '"done"' in out, out
        assert "import maths" not in out, out
        assert not [i for i in remaining if i.severity == "error"], remaining
        assert len(log) >= 7, log

    def t_fix_everything_c():
        if not linter_tool("cpp"):
            return  # no compiler on this machine - engine falls back
        src = ('#include <vector>\nint main() {\n'
               '    std::vectr<int> v = {1}\n    return 0;\n}\n')
        out, log, remaining = fix_everything(src, "cpp")
        assert "std::vector<int>" in out and "{1};" in out, out
        assert not [i for i in remaining if i.severity == "error"], remaining

    def t_html_repairs():
        # the exact report: "<button>hello<" said 'no problem'
        issues = check_source("<button>hello<", "html")
        assert issues, "must flag the incomplete tag"
        out, log, rem = fix_everything("<button>hello<", "html")
        assert out == "<button>hello</button>\n", repr(out)
        assert not [i for i in rem if i.severity == "error"], rem
        # force-closed element repaired in place, not at EOF
        out2, _, rem2 = fix_everything("<div>\n  <span>hi\n</div>\n", "html")
        p2, _, _ = html_scan(out2)
        assert not p2 and "</span>" in out2, out2
        # mismatched close renamed
        out3, _, _ = fix_everything("<div><span>x</div>\n", "html")
        p3, _, _ = html_scan(out3)
        assert not p3, out3
        # partial closing tag completed
        out4, _, _ = fix_everything("<div>\n<button>hi</butt\n</div>\n", "html")
        assert "</button>" in out4, out4
        p4, _, _ = html_scan(out4)
        assert not p4, out4
        # legal HTML5 (implied closes) must NOT be flagged
        assert not html_check("<ul>\n<li>a\n<li>b\n</ul>\n"), "li false alarm"
        assert not html_check('<!DOCTYPE html>\n<html><head><title>t</title>'
                              '</head>\n<body><p>x</p>\n<br>\n<img src="i">'
                              '\n</body></html>\n'), "page false alarm"

    def t_go_structure():
        shuffled = ('func main() {\n\tfmt.Println("hi")\n}\n\n'
                    'package main\n\nimport "fmt"\n')
        out, notes = go_structure_fix(shuffled)
        assert out.lstrip().startswith("package main"), out
        assert out.index("import") < out.index("func main"), out
        assert notes, notes
        # a well-ordered file is left alone
        good = 'package main\n\nimport "fmt"\n\nfunc main() {\n}\n'
        same, n2 = go_structure_fix(good)
        assert same == good and not n2, (same, n2)
        # missing closing brace gets closed at EOF
        out2, _, _ = fix_everything(
            'package main\n\nfunc main() {\n\tx := 1\n\t_ = x\n', "go")
        assert out2.rstrip().endswith("}"), out2

    def t_json_fixer():
        horror = ("{'name': 'Gecko', age: 5, \"tags\": ['a' 'b',], "
                  "active: True,}\n")
        out, log, rem = fix_everything(horror, "json")
        obj = json.loads(out)
        assert obj["active"] is True and obj["age"] == 5, obj
        assert obj["tags"] == ["a", "b"], obj
        out2, _, _ = fix_everything('// cfg\n{"a": [1, 2\n', "json")
        assert json.loads(out2) == {"a": [1, 2]}, out2

    def t_lang_fixers():
        out, _, _ = fix_everything("body {\n  color: red\n  margin: 0\n}\n",
                                   "css")
        assert out.count(";") >= 2, out
        out, _, _ = fix_everything("/* hdr\nbody {\n  color: red\n", "css")
        assert "*/" in out and out.rstrip().endswith("}"), out
        out, _, _ = fix_everything("name:gecko\n\tage: 5\n", "yaml")
        assert "name: gecko" in out and "\t" not in out, out
        out, _, _ = fix_everything("#Title\n\n```py\nx=1\n", "markdown")
        assert "# Title" in out and out.count("```") % 2 == 0, out
        out, _, _ = fix_everything("select * from users\n", "sql")
        assert out.rstrip().endswith(";"), out
        # keyword/end balancers (pure path also works without the tools)
        out, _, _ = fix_everything("def greet(name)\n  puts name\n", "ruby")
        assert out.rstrip().endswith("end"), out
        out, _, _ = fix_everything(
            "function f(x)\n  if x then\n    print(x)\n  end\n", "lua")
        assert out.rstrip().endswith("end"), out
        out, _, _ = fix_everything('if [ -f x ]; then\n  echo hi\n', "shell")
        assert out.rstrip().endswith("fi"), out

    def t_completion_smart():
        assert "upper" in (compute_completions('s = "hi"\ns.up', "s.up",
                                               "python") or []), "str method"
        got = compute_completions(
            "class A:\n  def __init__(self):\n    self.name = 1\n"
            "    self.nice = 2\n  def f(self):\n    x = self.n",
            "    x = self.n", "python")
        assert got and set(got) >= {"name", "nice"}, got
        got2 = compute_completions("obj.render(); obj.reload();\nobj.re",
                                   "obj.re", "javascript")
        assert got2 and "render" in got2 and "reload" in got2, got2

    def t_legacy_python_39():
        # Apple's macOS Python is 3.9: its parser says only "invalid syntax"
        # where new Pythons give helpful messages. The dispatcher must repair
        # from structure alone.
        def fake(msg, lineno, offset):
            e = SyntaxError(msg)
            e.lineno, e.offset, e.msg = lineno, offset, msg
            return e
        out, n = _py_dispatch("x = [1 2]\n", fake("invalid syntax", 1, 8))
        assert out == "x = [1, 2]\n" and n, (out, n)
        out, n = _py_dispatch("if x = 1:\n    pass\n",
                              fake("invalid syntax", 1, 6))
        assert "x == 1" in out, out
        out, n = _py_dispatch('s = "abc\n',
                              fake("EOL while scanning string literal", 1, 9))
        assert out == 's = "abc"\n', out
        out, n = _py_dispatch("f(\n  1 2,\n  3)\n",
                              fake("invalid syntax", 2, 5))
        assert "1, 2" in out, out
        # no false comma in valid constructs
        for good in ("x = [a for a in b]\n", "f(x, not y)\n",
                     "d = {1: 2, 3: 4}\n"):
            same, notes = _py_dispatch(good, fake("invalid syntax", 1, 2))
            assert "," not in [nn for nn in notes if "','" in nn] or \
                same.count(",") == good.count(","), (good, same)

    def t_tool_health():
        d = tempfile.mkdtemp()
        try:
            shim = os.path.join(d, "cc")
            with open(shim, "w") as f:
                f.write("#!/bin/sh\necho 'xcode-select: note: No developer "
                        "tools were found'\nexit 72\n")
            os.chmod(shim, 0o755)
            assert not _tool_healthy(shim), "Apple CLT shim must be rejected"
            assert _tool_healthy(sys.executable), "real python is healthy"
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def t_sql_builtin():
        kind, steps = build_steps("sql", "/tmp/x.sql")
        assert kind == "steps" and steps[0]["argv"][0] == sys.executable
        d = tempfile.mkdtemp()
        try:
            p = os.path.join(d, "q.sql")
            with open(p, "w") as f:
                f.write("create table t(a, b);\n"
                        "insert into t values (1, 'x');\n"
                        "insert into t values (2, 'y');\n"
                        "select * from t;\n")
            r = subprocess.run([sys.executable, "-c", SQL_RUNNER_SRC, p],
                               capture_output=True, text=True, timeout=20)
            assert r.returncode == 0, r.stderr
            assert "2 rows" in r.stdout and "y" in r.stdout, r.stdout
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def t_breakpoints_pdb():
        kind, steps = build_steps("python", "/tmp/x.py", debug=True,
                                  breakpoints=[3, 8])
        argv = steps[0]["argv"]
        assert "-m" in argv and "pdb" in argv, argv
        assert "b 3" in argv and "b 8" in argv and "c" in argv, argv

    def t_reindent():
        src = "def f():\n   x = 1\n   if x:\n         return x\n"
        out = reindent_python(src)
        assert out == "def f():\n    x = 1\n    if x:\n        return x\n", \
            repr(out)
        assert ast.dump(ast.parse(out)) == ast.dump(ast.parse(src))
        c = "int main(){\nint x=1;\nif(x){\nx=2;\n}\nreturn x;\n}\n"
        cout = reindent_braces(c, "c")
        assert "\n    int x=1;" in cout and "\n        x=2;" in cout, cout

    def t_format_source():
        out, tool = format_source("def f():\n   pass   \n", "python")
        assert out.endswith("\n") and "pass\n" in out and "   \n" not in out

    def t_completions():
        text = "apple banana apricot appliance apple\n"
        out = collect_completions(text, "ap", "python")
        assert out and out[0] == "apple", out
        assert "apricot" in out and "banana" not in out

    def t_compute_completions():
        # Word completion via the unified entry point.
        out = compute_completions("printed = 1\npri", "pri", "python")
        assert "print" in out, out
        # Python member completion by live stdlib introspection (offline).
        mem = compute_completions("import math\nx = math.sq", "x = math.sq",
                                  "python")
        assert "sqrt" in mem, mem
        assert all(m.startswith("sq") for m in mem), mem
        # Aliased import resolves.
        al = compute_completions("import os.path as p\np.jo", "p.jo", "python")
        assert "join" in al, al
        # Non-stdlib modules are never imported (safety).
        assert python_member_completions("import numpy as np\n", "np",
                                         "ar") is None

    def t_debuggers():
        # Debug must produce a debugger step for the common toolchains.
        for lang, needle in (("python", "pdb"),):
            k, steps = build_steps(lang, "/tmp/x" + LANGS[lang]["exts"][0],
                                   debug=True)
            assert k == "steps", (lang, k)
            assert any(needle in s.get("label", "") + " ".join(s["argv"])
                       for s in steps), (lang, steps)
        # Running must never crash for any language (returns a valid shape).
        for lid in LANG_ORDER:
            kind, _ = build_steps(lid, "/tmp/x" + LANGS[lid]["exts"][0])
            assert kind in ("steps", "info", "open"), (lid, kind)

    def t_placeholders():
        clean, spans = parse_placeholders("for «item» in «»:")
        assert clean == "for item in :", repr(clean)
        assert spans == [(4, 8), (12, 12)], spans

    def t_skeletons():
        missing = [l for l in LANG_ORDER if l not in SKELETONS]
        assert not missing, missing
        for lid, sk in SKELETONS.items():
            clean, _ = parse_placeholders(sk)
            assert "«" not in clean and "»" not in clean, lid

    def t_snippets():
        for fam, table in SNIPPETS.items():
            for k, v in table.items():
                clean, _ = parse_placeholders(v)
                assert "«" not in clean, (fam, k)

    def t_build_steps():
        kind, steps = build_steps("python", "/tmp/x.py")
        assert kind == "steps" and steps[0]["argv"][0] == sys.executable
        kind2, _ = build_steps("css", "/tmp/x.css")
        assert kind2 == "info"
        kind3, val3 = build_steps("html", "/tmp/x.html")
        assert kind3 == "open" and val3 == "/tmp/x.html"

    def t_markdown_html():
        html = markdown_to_html("# T\n\n- a\n\n`c`\n")
        assert "<h1>T</h1>" in html and "<li>a</li>" in html
        assert "<code>c</code>" in html

    def t_runner():
        r = StepRunner([{"argv": [sys.executable, "-c", "print(6*7)"]}])
        r.start()
        out, rc = [], None
        t0 = time.time()
        while time.time() - t0 < 30:
            try:
                ev = r.events.get(timeout=0.5)
            except _queue.Empty:
                continue
            if ev[0] == "done":
                rc = ev[1]
                break
            if ev[0] == "out":
                out.append(ev[1])
        assert rc == 0, rc
        assert "42" in "".join(out), out

    def t_depths():
        src = "f(\n  1,\n)\nx = 1\n"
        toks = tokenize(src, "python")
        li = LineIndex(src)
        _, _, _, events = scan_brackets(src, toks)
        d = depth_at_line_starts(li.starts, events)
        assert d[0] == 0 and d[1] == 1 and d[3] == 0, d

    run("polyglot header intact", t_polyglot)
    run("all %d language lexers work" % len(LANGS), t_lexers)
    run("python tokens classified", t_python_tokens)
    run("every word gets a color", t_every_word_colored)
    run("rainbow bracket depths", t_rainbow)
    run("line index math", t_lineindex)
    run("language detection", t_detect)
    run("outline extraction", t_outline_items)
    run("missing ':' detected + fixed", t_missing_colon)
    run("no false ':' positives", t_no_false_colon)
    run("unclosed '(' detected + fixed", t_unclosed_paren)
    run("unclosed string detected + fixed", t_unclosed_string)
    run("unclosed triple-quote detected", t_triple_unclosed)
    run("stray ')' detected", t_stray_close)
    run("python-2 print detected + fixed", t_print_py2)
    run("'=' in condition detected + fixed", t_eq_cond)
    run("missing ';' detected + fixed", t_semicolon)
    run("json validation", t_json_check)
    run("java class/file mismatch", t_java_rename)
    run("python syntax errors surfaced", t_compile_hint)
    run("python undefined name + unused import", t_py_undefined)
    run("python analysis: no false positives", t_py_no_false_positives)
    run("compiler diagnostic parsers", t_parse_diagnostics)
    run("external linter registry", t_linter_registry)
    run("comment splitting respects strings", t_split_comment)
    run("completion ranking", t_completions)
    run("edit application (fix-its)", t_apply_edits)
    run("unicode punctuation repair", t_unicode_fix)
    run("clang fix-it line parser", t_fixit_parse)
    run("python syntax repairs (comma/==/indent/string)", t_py_syntax_repairs)
    run("python semantic repairs (typos/imports)", t_py_semantic_repairs)
    run("FIX EVERYTHING: 8-error python file -> clean", t_fix_everything_python)
    run("FIX EVERYTHING: C++ typos + ';' -> clean", t_fix_everything_c)
    run("FIX EVERYTHING: html tags (<button>hello< ...)", t_html_repairs)
    run("FIX EVERYTHING: shuffled go file reassembled", t_go_structure)
    run("FIX EVERYTHING: json horror -> valid json", t_json_fixer)
    run("FIX EVERYTHING: css/yaml/md/sql/ruby/lua/shell", t_lang_fixers)
    run("completion: inferred types + self + dot-words", t_completion_smart)
    run("repairs work on Apple's Python 3.9 messages", t_legacy_python_39)
    run("fake Xcode-shim compilers are rejected", t_tool_health)
    run("SQL runs via the BUILT-IN sqlite (no install)", t_sql_builtin)
    run("gutter breakpoints reach the pdb debugger", t_breakpoints_pdb)
    run("layout: python + brace reindent", t_reindent)
    run("format document", t_format_source)
    run("completion: words + python member introspection", t_compute_completions)
    run("run/debug steps for every language", t_debuggers)
    run("placeholder parsing", t_placeholders)
    run("skeletons for every language", t_skeletons)
    run("snippets are well-formed", t_snippets)
    run("run steps (python/css/html)", t_build_steps)
    run("markdown preview renderer", t_markdown_html)
    run("subprocess runner end-to-end", t_runner)
    run("bracket depth per line", t_depths)

    print("-" * 46)
    if failures:
        print("FAILED: %d of %d tests" % (len(failures), total[0]))
        return 1
    print("All %d tests passed. GeskoIDE is ready." % total[0])
    return 0


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def main(argv):
    if "--version" in argv:
        print("%s %s" % (APP, VERSION))
        return 0
    if "--help" in argv or "-h" in argv:
        print(
            "%s %s - a fast, friendly, fully offline code editor.\n\n"
            "Usage:\n"
            "  GeskoIDE.command [files...]   open files (or the welcome screen)\n"
            "  GeskoIDE.command --selftest   run the built-in test suite\n"
            "  GeskoIDE.command --version    print the version\n"
            "  GeskoIDE.command --help       show this help\n\n"
            "No internet, no accounts, no APIs. Knows %d languages, colors "
            "every token,\nauto-completes and auto-fixes on Tab, and runs your "
            "code with the tools\nalready on your computer."
            % (APP, VERSION, len(LANGS)))
        return 0
    if "--selftest" in argv:
        return selftest()
    files = [a for a in argv if not a.startswith("-")]
    if not TK_OK:
        sys.stderr.write(
            "GeskoIDE needs Python's Tk support (tkinter), which was not "
            "found.\n"
            "  macOS:          install Python 3 from python.org (includes "
            "Tk),\n"
            "                  or run:  xcode-select --install\n"
            "  Debian/Ubuntu:  sudo apt install python3-tk\n"
            "  Fedora:         sudo dnf install python3-tkinter\n")
        return 1
    try:
        app = GeskoApp(files)
    except tk.TclError as ex:
        sys.stderr.write(
            "GeskoIDE could not open a window (%s).\n"
            "It needs a graphical session - on a headless/SSH machine, "
            "run it on the desktop instead.\n" % ex)
        return 1
    app.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
