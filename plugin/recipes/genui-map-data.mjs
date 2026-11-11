import fs from 'node:fs';
import path from 'node:path';

const [source, target] = process.argv.slice(2);
if (!source || !target) throw Error('Usage: node genui-map-data.mjs <echarts-4.9.0-package> <genui-source>');
const maps = {};
const index = [];
const destination = path.join(target, 'assets/maps');
fs.mkdirSync(destination, { recursive: true });
function visit(dir, prefix = '') {
  for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
    if (item.isDirectory()) visit(path.join(dir, item.name), prefix + item.name + '/');
    else if (item.name.endsWith('.json')) {
      const file = prefix + item.name;
      const json = JSON.parse(fs.readFileSync(path.join(dir, item.name), 'utf8'));
      const name = path.basename(item.name, '.json');
      const js = path.join(source, 'map/js', prefix, name + '.js');
      const chinese = fs.existsSync(js) ? fs.readFileSync(js, 'utf8').match(/registerMap\('([^']+)'/)?.[1] : undefined;
      // 每份几何只存一次，中文全称和文件名共享同一对象。
      const aliases = [...new Set([name, chinese].filter(Boolean))];
      if (name === 'china') aliases.push('中国');
      if (name === 'world') aliases.push('世界');
      const full = chinese && ({ 北京: '北京市', 天津: '天津市', 上海: '上海市', 重庆: '重庆市',
        内蒙古: '内蒙古自治区', 广西: '广西壮族自治区', 宁夏: '宁夏回族自治区', 新疆: '新疆维吾尔自治区',
        西藏: '西藏自治区', 香港: '香港特别行政区', 澳门: '澳门特别行政区' }[chinese]
        ?? (prefix === 'province/' ? chinese + '省' : undefined));
      if (full) aliases.push(full);
      maps[name] = { aliases, data: json };
      index.push({ file, aliases });
      fs.mkdirSync(path.dirname(path.join(destination, file)), { recursive: true });
      fs.copyFileSync(path.join(dir, item.name), path.join(destination, file));
    }
  }
}
visit(path.join(source, 'map/json'));
fs.writeFileSync(path.join(target, 'src/client/offline-maps.ts'),
  "// 固定版本地图随完整引擎注册，包含独立 GeoJSON 原始文件供离线使用。\n"
  + "import { registerMap } from 'echarts'\n"
  + 'const maps = JSON.parse(' + JSON.stringify(JSON.stringify(maps)) + ') as Record<string, {aliases: string[], data: Parameters<typeof registerMap>[1]}>\n'
  + 'for (const { aliases, data } of Object.values(maps)) for (const name of aliases) registerMap(name, data)\n');
for (const file of ['LICENSE', 'NOTICE']) fs.copyFileSync(path.join(source, file), path.join(destination, file));
fs.writeFileSync(path.join(destination, 'index.json'), JSON.stringify({
  source: 'https://registry.npmjs.org/echarts/-/echarts-4.9.0.tgz',
  sha256: 'd2bdf8af1b218d3885a518072788a3b7f0c2d3f8925ec8585a36be5ee5add3f2',
  note: 'Historical ECharts 4.9.0 map data; boundaries are not maintained as current administrative data.', maps: index,
}, null, 2) + '\n');
console.log(`Bundled ${index.length} GeoJSON maps`);
