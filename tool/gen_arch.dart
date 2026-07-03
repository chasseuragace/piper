// ============================================================
// ARCHITECTURE GENERATOR — the doc that cannot lie about structure
// ============================================================
//
// Piper's own pattern, turned on itself. Every STRUCTURAL fact in the output
// — the module map, the symbol signatures, the dependency edges, the order of
// the speak pipeline, the tuning-knob values — is read from the Dart AST via
// `package:analyzer` (parse-only; no type resolution needed). Those facts are
// deterministic and cannot drift from the code, because they ARE the code.
//
// The one non-structural field, a symbol's one-line INTENT, is pulled from the
// nearest doc/`//` comment. That text can lag, but it never invents structure —
// exactly the "cognitive layer narrates over deterministic facts, never
// fabricates them" rule the rest of the system lives by.
//
// USAGE
//   dart run tool/gen_arch.dart           # (re)write ARCHITECTURE.generated.md
//   dart run tool/gen_arch.dart --check   # exit 1 if the file is stale (for CI)
//
// The --check mode is the actual anti-rot guarantee: wire it into CI and the
// build fails the moment code structure drifts from the committed doc.

import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

const _outputName = 'ARCHITECTURE.generated.md';

// Root entrypoints live at repo root by design (external MCP configs reference
// them by path); library code lives under src/.
const _rootEntrypoints = [
  'piper_mcp_server.dart',
  'piper_http_mcp_server.dart',
  'piper_tts.dart',
  'report_calibration.dart',
];

void main(List<String> args) {
  final check = args.contains('--check');
  final root = _findRepoRoot();
  if (root == null) {
    stderr.writeln('error: run from the repo root (no pubspec.yaml/src found)');
    exit(2);
  }

  final files = _gatherFiles(root);
  final infos = [for (final f in files) _parseFile(root, f)];

  final content = _render(root, infos);

  final outFile = File(p.join(root, _outputName));
  if (check) {
    final existing = outFile.existsSync() ? outFile.readAsStringSync() : '';
    if (existing != content) {
      stderr.writeln(
        'ARCHITECTURE is STALE — code structure has drifted from $_outputName.\n'
        'Run: dart run tool/gen_arch.dart',
      );
      exit(1);
    }
    stdout.writeln('$_outputName is up to date.');
    return;
  }

  outFile.writeAsStringSync(content);
  stdout.writeln('Wrote $_outputName (${infos.length} files).');
}

// --- repo root: walk up from cwd until we see pubspec.yaml + src/ ------------

String? _findRepoRoot() {
  var dir = Directory.current.absolute.path;
  for (var i = 0; i < 8; i++) {
    if (File(p.join(dir, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir, 'src')).existsSync()) {
      return dir;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}

// --- file gathering ----------------------------------------------------------

List<String> _gatherFiles(String root) {
  final out = <String>[];
  final srcDir = Directory(p.join(root, 'src'));
  if (srcDir.existsSync()) {
    for (final e in srcDir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) {
        out.add(p.relative(e.path, from: root));
      }
    }
  }
  for (final e in _rootEntrypoints) {
    if (File(p.join(root, e)).existsSync()) out.add(e);
  }
  out.sort();
  return out;
}

// --- per-file model ----------------------------------------------------------

class _Symbol {
  final String kind; // class | enum | function | const | var
  final String name;
  final String signature;
  final String doc;
  final int offset;
  _Symbol(this.kind, this.name, this.signature, this.doc, this.offset);
}

class _FileInfo {
  final String relPath;
  final String module; // directory bucket, e.g. src/observation
  final String header; // file-level intent (top banner/comment)
  final List<_Symbol> symbols;
  final List<String> imports; // repo-relative paths of intra-project imports
  final CompilationUnit unit;
  final List<String> lines;
  _FileInfo(this.relPath, this.module, this.header, this.symbols, this.imports,
      this.unit, this.lines);
}

_FileInfo _parseFile(String root, String relPath) {
  final content = File(p.join(root, relPath)).readAsStringSync();
  final lines = content.split('\n');
  final result = parseString(content: content, throwIfDiagnostics: false);
  final unit = result.unit;

  final module = p.dirname(relPath) == '.' ? '(root)' : p.dirname(relPath);

  // File-level intent: the first meaningful comment block near the top, minus
  // the decorative banner lines.
  final header = _headerComment(lines);

  final symbols = <_Symbol>[];
  final imports = <String>[];

  for (final d in unit.directives) {
    if (d is ImportDirective) {
      final uri = d.uri.stringValue;
      if (uri == null) continue;
      if (uri.startsWith('dart:') || uri.startsWith('package:')) continue;
      final resolved =
          p.normalize(p.join(p.dirname(relPath), uri)).replaceAll('\\', '/');
      imports.add(resolved);
    }
  }
  imports.sort();

  for (final m in unit.declarations) {
    final startLine = unit.lineInfo.getLocation(m.offset).lineNumber;
    final doc = _docFor(m, lines, startLine);
    if (m is ClassDeclaration) {
      final nm = m.namePart.typeName.lexeme;
      final tp = m.namePart.typeParameters?.toSource() ?? '';
      symbols.add(_Symbol('class', nm, 'class $nm$tp', doc, m.offset));
    } else if (m is EnumDeclaration) {
      final nm = m.namePart.typeName.lexeme;
      symbols.add(_Symbol('enum', nm, 'enum $nm', doc, m.offset));
    } else if (m is MixinDeclaration) {
      symbols.add(_Symbol('mixin', m.name.lexeme, 'mixin ${m.name.lexeme}', doc, m.offset));
    } else if (m is FunctionDeclaration) {
      final fe = m.functionExpression;
      final ret = m.returnType?.toSource();
      final tp = fe.typeParameters?.toSource() ?? '';
      final params = fe.parameters?.toSource() ?? '()';
      final sig = '${ret == null ? '' : '$ret '}${m.name.lexeme}$tp$params';
      symbols.add(_Symbol('function', m.name.lexeme, sig, doc, m.offset));
    } else if (m is TopLevelVariableDeclaration) {
      final vars = m.variables;
      for (final v in vars.variables) {
        final isConst = vars.isConst;
        final type = vars.type?.toSource();
        final init = v.initializer?.toSource();
        final sig = [
          if (isConst) 'const',
          if (type != null) type,
          v.name.lexeme,
          if (init != null) '= $init',
        ].join(' ');
        symbols.add(_Symbol(isConst ? 'const' : 'var', v.name.lexeme, sig, doc, m.offset));
      }
    }
  }
  symbols.sort((a, b) => a.offset.compareTo(b.offset));

  return _FileInfo(relPath, module, header, symbols, imports, unit, lines);
}

// The top-of-file intent: first run of comment lines, decorative `====` banners
// and shebang-ish noise stripped, capped to a couple of lines.
String _headerComment(List<String> lines) {
  final buf = <String>[];
  var started = false;
  for (final raw in lines.take(30)) {
    final line = raw.trimLeft();
    if (line.startsWith('//')) {
      final text = _stripComment(line);
      if (_isBanner(text)) {
        if (started && buf.isNotEmpty) break;
        continue;
      }
      if (text.isEmpty) {
        if (started) break;
        continue;
      }
      started = true;
      buf.add(text);
      if (buf.length >= 2) break;
    } else if (started) {
      break;
    } else if (line.isNotEmpty && !line.startsWith('import ') &&
        !line.startsWith('library ')) {
      // Hit real code before any comment — no header.
      break;
    }
  }
  return buf.join(' ');
}

// Intent for one declaration: a `///` doc comment if present, else the run of
// `//` lines immediately above it (banners stripped). Structure never depends
// on this — it is descriptive text only.
String _docFor(AnnotatedNode m, List<String> lines, int startLine) {
  final dc = m.documentationComment;
  if (dc != null) {
    final parts = dc.tokens
        .map((t) => _stripComment(t.lexeme))
        .where((s) => s.isNotEmpty && !_isBanner(s))
        .toList();
    if (parts.isNotEmpty) return _firstSentence(parts.join(' '));
  }
  // Scan upward from the line above the declaration (startLine is 1-based).
  final collected = <String>[];
  for (var i = startLine - 2; i >= 0 && i < lines.length; i--) {
    final line = lines[i].trimLeft();
    if (!line.startsWith('//')) break;
    final text = _stripComment(line);
    if (_isBanner(text)) break;
    collected.add(text);
  }
  final ordered = collected.reversed.where((s) => s.isNotEmpty).toList();
  return ordered.isEmpty ? '' : _firstSentence(ordered.join(' '));
}

String _stripComment(String s) {
  var t = s.trim();
  if (t.startsWith('///')) {
    t = t.substring(3);
  } else if (t.startsWith('//')) {
    t = t.substring(2);
  }
  if (t.startsWith('*')) t = t.substring(1);
  return t.trim();
}

bool _isBanner(String s) => s.isEmpty ? false : RegExp(r'^[=\-*\s]+$').hasMatch(s);

String _firstSentence(String s) {
  final trimmed = s.trim();
  final m = RegExp(r'^(.*?[.:])(\s|$)').firstMatch(trimmed);
  final one = m != null ? m.group(1)! : trimmed;
  return one.length > 160 ? '${one.substring(0, 157)}…' : one;
}

// --- the speak pipeline: call order inside _handleCallTool -------------------

// Every top-level function name in the project — used to filter the raw call
// stream down to project-defined steps (drop stdlib/method noise).
Set<String> _projectFunctionNames(List<_FileInfo> infos) => {
      for (final f in infos)
        for (final s in f.symbols)
          if (s.kind == 'function') s.name,
    };

// A step in the pipeline: either a call, or a conditional whose arms are their
// own sub-sequences. This is what lets us lift `if`/`else` tails out of the
// main spine instead of flattening everything into one misleading line.
sealed class _PNode {}

class _PCall extends _PNode {
  final String name;
  _PCall(this.name);
}

class _PBranch extends _PNode {
  final String cond;
  final List<_PNode> thenArm;
  final List<_PNode> elseArm;
  _PBranch(this.cond, this.thenArm, this.elseArm);
}

List<_PNode> _speakPipeline(List<_FileInfo> infos) {
  final server = infos.where((f) => f.relPath == 'piper_mcp_server.dart').toList();
  if (server.isEmpty) return const [];
  FunctionDeclaration? handler;
  for (final d in server.first.unit.declarations) {
    if (d is FunctionDeclaration && d.name.lexeme == '_handleCallTool') {
      handler = d;
      break;
    }
  }
  final body = handler?.functionExpression.body;
  if (body is! BlockFunctionBody) return const [];
  return _walkStmts(body.block.statements, _projectFunctionNames(infos));
}

// Walk statements in order. Non-`if` statements contribute their project calls
// to the current (main) sequence; an `if` becomes a branch whose then/else arms
// are walked recursively — so fallback tails never pollute the main line.
List<_PNode> _walkStmts(List<Statement> stmts, Set<String> fns) {
  final out = <_PNode>[];
  for (final s in stmts) {
    if (s is IfStatement) {
      // Calls in the condition itself run before the branch is taken.
      for (final c in _callsIn(s.expression, fns)) out.add(_PCall(c));
      final thenArm = _walkStmts(_stmtsOf(s.thenStatement), fns);
      final elseArm = s.elseStatement == null
          ? <_PNode>[]
          : _walkStmts(_stmtsOf(s.elseStatement!), fns);
      // Drop guard-only ifs (arg validation, early returns with no project work).
      if (_hasCall(thenArm) || _hasCall(elseArm)) {
        out.add(_PBranch(_short(s.expression.toSource()), thenArm, elseArm));
      }
    } else {
      for (final c in _callsIn(s, fns)) out.add(_PCall(c));
    }
  }
  return _collapse(out);
}

List<Statement> _stmtsOf(Statement s) =>
    s is Block ? s.statements.toList() : [s];

// Project-defined calls within one node, in source order, consecutive repeats
// collapsed.
List<String> _callsIn(AstNode node, Set<String> fns) {
  final col = _CallCollector();
  node.accept(col);
  col.calls.sort((a, b) => a.key.compareTo(b.key));
  final out = <String>[];
  for (final e in col.calls) {
    if (!fns.contains(e.value)) continue;
    if (out.isNotEmpty && out.last == e.value) continue;
    out.add(e.value);
  }
  return out;
}

bool _hasCall(List<_PNode> nodes) => nodes.any((n) =>
    n is _PCall || (n is _PBranch && (_hasCall(n.thenArm) || _hasCall(n.elseArm))));

// Collapse consecutive identical calls at the same level (e.g. two adjacent
// summarizeObservation calls in one arm).
List<_PNode> _collapse(List<_PNode> nodes) {
  final out = <_PNode>[];
  for (final n in nodes) {
    if (n is _PCall && out.isNotEmpty && out.last is _PCall &&
        (out.last as _PCall).name == n.name) {
      continue;
    }
    out.add(n);
  }
  return out;
}

String _short(String cond) {
  final one = cond.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 60 ? '${one.substring(0, 57)}…' : one;
}

class _CallCollector extends RecursiveAstVisitor<void> {
  final List<MapEntry<int, String>> calls = [];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    calls.add(MapEntry(node.offset, node.methodName.name));
    super.visitMethodInvocation(node);
  }
}

// --- rendering ---------------------------------------------------------------

String _render(String root, List<_FileInfo> infos) {
  final b = StringBuffer();
  b.writeln('<!-- GENERATED by tool/gen_arch.dart — DO NOT EDIT BY HAND. -->');
  b.writeln('<!-- Regenerate: dart run tool/gen_arch.dart  |  CI check: --check -->');
  b.writeln();
  b.writeln('# Piper — Generated Architecture');
  b.writeln();
  b.writeln('Structure extracted from the Dart AST; it cannot drift from the '
      'code. Intent lines are pulled from each symbol\'s nearest comment and are '
      'descriptive only. For the *why* behind the design, read the Balcony '
      'Pattern essays — this file is the *what* and *how-connected*.');
  b.writeln();

  _renderModuleMap(b, infos);
  _renderDependencyGraph(b, infos);
  _renderPipeline(b, infos);
  _renderKnobs(b, infos);

  return b.toString();
}

void _renderModuleMap(StringBuffer b, List<_FileInfo> infos) {
  b.writeln('## Module map');
  b.writeln();
  final byModule = <String, List<_FileInfo>>{};
  for (final f in infos) {
    byModule.putIfAbsent(f.module, () => []).add(f);
  }
  final modules = byModule.keys.toList()..sort();
  for (final mod in modules) {
    b.writeln('### `$mod`');
    b.writeln();
    for (final f in byModule[mod]!) {
      final name = p.basename(f.relPath);
      final desc = f.header.isEmpty ? '' : ' — ${f.header}';
      b.writeln('**`$name`**$desc');
      b.writeln();
      if (f.symbols.isEmpty) {
        b.writeln('_(no top-level declarations)_');
        b.writeln();
        continue;
      }
      for (final s in f.symbols) {
        final d = s.doc.isEmpty ? '' : ' — ${s.doc}';
        b.writeln('- `${s.signature}`$d');
      }
      b.writeln();
    }
  }
}

void _renderDependencyGraph(StringBuffer b, List<_FileInfo> infos) {
  b.writeln('## Dependency graph');
  b.writeln();
  b.writeln('Intra-project imports (relative imports only; `dart:` and '
      '`package:` edges omitted).');
  b.writeln();
  final known = {for (final f in infos) f.relPath};
  final ids = <String, String>{};
  var n = 0;
  String idFor(String path) => ids.putIfAbsent(path, () => 'n${n++}');

  final edges = <String>[];
  for (final f in infos) {
    for (final imp in f.imports) {
      if (!known.contains(imp)) continue;
      edges.add('  ${idFor(f.relPath)} --> ${idFor(imp)}');
    }
  }
  edges.sort();

  b.writeln('```mermaid');
  b.writeln('flowchart LR');
  final labelled = ids.keys.toList()..sort((a, c) => ids[a]!.compareTo(ids[c]!));
  for (final path in labelled) {
    b.writeln('  ${ids[path]}["$path"]');
  }
  for (final e in edges) {
    b.writeln(e);
  }
  b.writeln('```');
  b.writeln();
}

void _renderPipeline(StringBuffer b, List<_FileInfo> infos) {
  b.writeln('## The speak pipeline');
  b.writeln();
  b.writeln('Project-defined calls inside `_handleCallTool`. The main line is the '
      'deterministic ladder that runs every turn; conditional tails (the '
      'judge-vs-fallback split, ack recording) are lifted into their own section '
      'so the ladder reads clean. Granularity is statement-level.');
  b.writeln();
  final nodes = _speakPipeline(infos);
  if (nodes.isEmpty) {
    b.writeln('_(could not locate `_handleCallTool`)_');
    b.writeln();
    return;
  }

  // Main-path spine: the top-level calls, in order (branches shown below).
  final spine = [for (final n in nodes) if (n is _PCall) n.name];
  b.writeln('**Main path**');
  b.writeln();
  b.writeln('```mermaid');
  b.writeln('flowchart TD');
  for (var i = 0; i < spine.length; i++) {
    b.writeln('  s$i["${spine[i]}"]');
    if (i > 0) b.writeln('  s${i - 1} --> s$i');
  }
  b.writeln('```');
  b.writeln();

  // Branch tails: every top-level conditional, arms rendered recursively.
  final branches = nodes.whereType<_PBranch>().toList();
  if (branches.isNotEmpty) {
    b.writeln('**Conditional branches** (run only under their guard):');
    b.writeln();
    for (final br in branches) {
      _renderBranch(b, br, '');
    }
    b.writeln();
  }
}

void _renderBranch(StringBuffer b, _PBranch br, String indent) {
  b.writeln('$indent- **if `${br.cond}`**');
  if (_hasCall(br.thenArm)) {
    b.writeln('$indent  - _then:_');
    _renderArm(b, br.thenArm, '$indent    ');
  }
  if (_hasCall(br.elseArm)) {
    b.writeln('$indent  - _else:_');
    _renderArm(b, br.elseArm, '$indent    ');
  }
}

void _renderArm(StringBuffer b, List<_PNode> nodes, String indent) {
  for (final n in nodes) {
    if (n is _PCall) {
      b.writeln('$indent- `${n.name}`');
    } else if (n is _PBranch) {
      _renderBranch(b, n, indent);
    }
  }
}

void _renderKnobs(StringBuffer b, List<_FileInfo> infos) {
  b.writeln('## Tuning knobs');
  b.writeln();
  b.writeln('Top-level `const` durations and numbers — the calibration surface. '
      'Values are read live from source.');
  b.writeln();
  b.writeln('| Constant | Value | Where | Intent |');
  b.writeln('| --- | --- | --- | --- |');
  final rows = <String>[];
  for (final f in infos) {
    for (final s in f.symbols) {
      if (s.kind != 'const') continue;
      final v = _constValue(s.signature);
      if (v == null) continue; // not a Duration/number knob
      final doc = s.doc.replaceAll('|', '\\|');
      rows.add('| `${s.name}` | `$v` | `${p.basename(f.relPath)}` | $doc |');
    }
  }
  for (final r in rows) {
    b.writeln(r);
  }
  b.writeln();
}

// Pull the initializer out of a const signature, keeping only Duration(...) or
// numeric-literal knobs (the things you actually tune).
String? _constValue(String signature) {
  final eq = signature.indexOf('= ');
  if (eq < 0) return null;
  final v = signature.substring(eq + 2).trim();
  if (v.startsWith('Duration(')) return v;
  if (RegExp(r'^-?\d').hasMatch(v)) return v;
  return null;
}
