import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const started = performance.now();
const args = process.argv.slice(2);
const catalog = JSON.parse(fs.readFileSync(path.join(root, 'tool/ui_capture/scenarios.json'), 'utf8'));
if (new Set(catalog.map(s => s.id)).size !== catalog.length) throw new Error('捕获清单含重复状态 ID');
const options = { platform: 'all', theme: 'all', feature: 'all', only: '*', size: 'all', jobs: String(Math.min(4, Math.max(1, Math.floor(os.cpus().length / 2)))), out: 'build/ui-capture' };
const featureAliases = { '首页': 'home', '聚合': 'aggregation', '片库': 'library', '详情': 'detail', '搜索': 'search', '服务器': 'servers', '设置': 'settings', '登录': 'login', '播放器': 'player', '弹幕': 'danmaku' };
if (args.includes('--help')) {
  console.log(`Usage: node tool/capture-ui.mjs [options]
  --platform all|desktop|phone|tv      default: all
  --theme all|dark|light               default: all
  --feature home,aggregation,entry,library,detail,search,servers,settings,login,player,danmaku
  --only 'server-*,danmaku-search-*'    exact state IDs or * / ? patterns
  --size 360,412,1024,1440,1920,3840    profile widths, default: all
  --list                              list matching states without rendering
  --jobs 4                            parallel profiles (default: half CPUs, max 4)
  --out build/ui-capture               each run gets a separate directory
Filters combine with AND. Lists within one filter combine with OR.
Examples:
  node tool/capture-ui.mjs --feature 弹幕 --platform phone
  node tool/capture-ui.mjs --only server-delete-confirm --theme light
  node tool/capture-ui.mjs --only '*loading*' --list`);
  process.exit(0);
}
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--list') continue;
  const key = args[i].replace(/^--/, '');
  if (!(key in options) || !args[i + 1]) throw new Error(`未知参数：${args[i]}`);
  options[key] = args[++i];
}
if (!['all', 'desktop', 'phone', 'tv'].includes(options.platform) || !['all', 'dark', 'light'].includes(options.theme)) throw new Error('平台或主题无效');
if (!/^[1-9]\d*$/.test(options.jobs) || !Number.isSafeInteger(Number(options.jobs))) throw new Error('--jobs 必须是正整数');
const features = options.feature === 'all' ? [] : options.feature.split(',').map(f => featureAliases[f] ?? f);
const validFeatures = new Set(catalog.map(s => s.feature));
for (const f of features) if (!validFeatures.has(f)) throw new Error(`未知功能：${f}`);
const profiles = [{ platform: 'desktop', width: 1440 }, { platform: 'desktop', width: 1024 }, { platform: 'phone', width: 360 }, { platform: 'phone', width: 412 }, { platform: 'tv', width: 1920 }, { platform: 'tv', width: 3840 }].filter(p => (options.platform === 'all' || p.platform === options.platform) && (options.size === 'all' || options.size.split(',').includes(String(p.width))));
if (!profiles.length || (options.size !== 'all' && options.size.split(',').some(s => !['360', '412', '1024', '1440', '1920', '3840'].includes(s)))) throw new Error('尺寸与平台没有匹配的配置');
const glob = pattern => new RegExp(`^${pattern.split('').map(c => c === '*' ? '.*' : c === '?' ? '.' : c.replace(/[\\^$+.[\]{}()|]/g, '\\$&')).join('')}$`);
const patterns = options.only.split(',').map(glob);
const selected = catalog.filter(s => (!features.length || features.includes(s.feature)) && patterns.some(p => p.test(s.id)) && profiles.some(p => s.platforms.includes(p.platform)));
if (!selected.length) throw new Error('没有匹配的捕获状态。使用 --list 查看支持的状态。');
if (args.includes('--list')) {
  console.log(selected.map(s => `${s.id.padEnd(42)} ${s.feature.padEnd(9)} ${s.platforms.join(',')}`).join('\n'));
  process.exit(0);
}
const font = process.env.RILLIGHT_CAPTURE_FONT ?? [
  '/System/Library/Fonts/Hiragino Sans GB.ttc',
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  path.join(process.env.WINDIR ?? 'C:\\Windows', 'Fonts', 'msyh.ttc'),
].find(p => fs.existsSync(p));
if (!font || !fs.existsSync(font)) throw new Error('请设置 RILLIGHT_CAPTURE_FONT，指向支持中文的 TTF/OTF/TTC 字体。');
const outputRoot = path.resolve(root, options.out);
fs.mkdirSync(outputRoot, { recursive: true });
// Atomic unique directories also isolate two invocations in the same millisecond.
const out = fs.mkdtempSync(path.join(outputRoot, `${new Date().toISOString().replace(/[:.]/g, '-')}-`));
const flutter = process.env.FLUTTER ?? (os.platform() === 'win32' ? 'flutter.bat' : 'flutter');
const version = spawnSync(flutter, ['--version', '--machine'], { cwd: root, encoding: 'utf8', shell: os.platform() === 'win32' });
if (version.status !== 0) throw new Error(version.error?.message ?? version.stderr);
const flutterVersion = JSON.parse(version.stdout);
const activeProfiles = profiles.filter(p => selected.some(s => s.platforms.includes(p.platform)));
const themes = options.theme === 'all' ? ['dark', 'light'] : [options.theme];
// One Flutter invocation owns compilation/native assets. Its test runner
// isolates each profile/theme in a separate process, sharing compiled imports.
const drivers = path.join(out, 'drivers');
fs.mkdirSync(drivers);
const captureImport = pathToFileURL(path.join(root, 'tool/ui_capture/capture.dart')).href.replaceAll("'", '%27');
const shards = activeProfiles.flatMap(p => themes.map(theme => ({ ...p, theme })));
for (const shard of shards) {
  fs.writeFileSync(path.join(drivers, `${shard.platform}-${shard.width}-${shard.theme}_test.dart`),
    `import '${captureImport}' as capture;\nvoid main() => capture.runCapture(profile: '${shard.platform}-${shard.width}', captureTheme: '${shard.theme}');\n`);
}
const jobs = Math.min(Number(options.jobs), shards.length);
const env = { ...process.env, RILLIGHT_CAPTURE_OUT: out, RILLIGHT_CAPTURE_FONT: path.resolve(font), RILLIGHT_CAPTURE_PLATFORM: options.platform, RILLIGHT_CAPTURE_THEME: options.theme, RILLIGHT_CAPTURE_SIZE: options.size, RILLIGHT_CAPTURE_PROFILES: activeProfiles.map(p => `${p.platform}-${p.width}`).join(','), RILLIGHT_CAPTURE_STATES: selected.map(s => s.id).join(','), RILLIGHT_CAPTURE_FEATURES: [...new Set(selected.map(s => s.feature))].join(',') };
const log = fs.createWriteStream(path.join(out, 'capture.log'));
const renderStarted = performance.now();
// --version has already bootstrapped Flutter. On Windows launch that SDK's
// native Dart executable directly: cmd/bat would reinterpret output paths
// containing spaces or shell metacharacters instead of passing one argument.
const executable = os.platform() === 'win32' ? path.join(flutterVersion.flutterRoot, 'bin/cache/dart-sdk/bin/dart.exe') : flutter;
const bootstrapArgs = os.platform() === 'win32' ? [
  `--packages=${path.join(flutterVersion.flutterRoot, 'packages/flutter_tools/.dart_tool/package_config.json')}`,
  path.join(flutterVersion.flutterRoot, 'bin/cache/flutter_tools.snapshot'),
] : [];
const child = spawn(executable, [...bootstrapArgs, 'test', '--no-pub', `--concurrency=${jobs}`, '--reporter=expanded', drivers], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
for (const stream of [child.stdout, child.stderr]) stream.on('data', data => { process.stdout.write(data); log.write(data); });
const status = await new Promise(resolve => { child.on('error', error => { log.write(String(error)); resolve(1); }); child.on('close', resolve); });
const renderSeconds = (performance.now() - renderStarted) / 1000;
await new Promise(resolve => log.end(resolve));
const captures = fs.readdirSync(out).filter(n => /^(desktop|phone|tv)-\d+-(dark|light)\.json$/.test(n)).flatMap(n => JSON.parse(fs.readFileSync(path.join(out, n), 'utf8')));
const missing = profiles.flatMap(p => themes.flatMap(theme => selected.filter(s => s.platforms.includes(p.platform)).filter(s => !captures.some(c => c.platform === p.platform && c.profileWidth === p.width && c.theme === theme && c.state === s.id)).map(s => ({ platform: p.platform, width: p.width, theme, state: s.id }))));
for (const capture of captures) {
  capture.feature = catalog.find(s => s.id === capture.state)?.feature;
  capture.sha256 = crypto.createHash('sha256').update(fs.readFileSync(path.join(out, capture.file))).digest('hex');
}
const manifest = { kind: 'synthetic-flutter-prototype', success: status === 0 && captures.length > 0 && missing.length === 0, host: { platform: os.platform(), arch: os.arch() }, flutter: flutterVersion, font: { path: font, sha256: crypto.createHash('sha256').update(fs.readFileSync(font)).digest('hex') }, options, missing, captures };
manifest.timing = { jobs, shards: shards.length, renderSeconds, totalSeconds: (performance.now() - started) / 1000 };
fs.writeFileSync(path.join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
fs.writeFileSync(path.join(out, 'index.html'), `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>灯川 · UI 捕获</title><style>
body{margin:0;background:#101114;color:#f5f2ec;font:15px system-ui}header{position:sticky;top:0;padding:20px 4vw;background:#191b20;z-index:2}h1{font-size:24px;margin:0 0 8px}p{color:#b3afa6}select,input{font:inherit;padding:10px;margin:4px;border:1px solid #555;border-radius:8px;background:#25272d;color:inherit}main{padding:24px 4vw;display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:24px}figure{margin:0;padding:12px;border:1px solid #34363d;border-radius:12px}img{width:100%;height:340px;object-fit:contain;background:#070709}figcaption{padding:12px 0 0}a{color:inherit}small{display:block;color:#b3afa6;margin-top:5px}[hidden]{display:none!important}</style><header><h1>灯川 · 原型交互捕获</h1><p>${manifest.success ? '捕获完成' : '捕获失败：以下仅为已完成状态，请查看终端错误'} · ${captures.length} 张 · 合成媒体，不代表原生播放验收</p><select id="platform"><option value="">全部平台</option><option>desktop</option><option>phone</option><option>tv</option></select><select id="theme"><option value="">全部主题</option><option>dark</option><option>light</option></select><input id="query" placeholder="筛选状态，如 loading / hover / speed" aria-label="筛选状态"></header><main>${captures.map(c => `<figure data-platform="${escape(c.platform)}" data-theme="${escape(c.theme)}" data-name="${escape(c.state)}"><a href="${escape(c.file)}"><img loading="lazy" src="${escape(c.file)}" alt="${escape(c.state)}"></a><figcaption>${escape(c.state)}<small>${escape(c.platform)} · ${escape(c.theme)} · ${c.width} × ${c.height}</small></figcaption></figure>`).join('')}</main><script>const controls=['platform','theme','query'].map(id=>document.getElementById(id));function filter(){for(const f of document.querySelectorAll('figure'))f.hidden=!!((controls[0].value&&f.dataset.platform!==controls[0].value)||(controls[1].value&&f.dataset.theme!==controls[1].value)||!f.dataset.name.includes(controls[2].value.toLowerCase()));}controls.forEach(c=>c.addEventListener('input',filter));</script></html>`);
console.log(`\n${path.join(out, 'index.html')}`);
console.log(`${captures.length} captures · ${jobs} jobs · ${manifest.timing.totalSeconds.toFixed(1)}s`);
if (missing.length) console.error(`缺少 ${missing.length} 个预期状态，详见 manifest.json。`);
if (!manifest.success) process.exitCode = 1;
