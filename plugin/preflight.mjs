import { loadConfig, directoryName, environment } from './common.mjs';

const [file, only] = process.argv.slice(2);
const plugins = loadConfig(file, only);
const env = environment();
for (const plugin of plugins) {
  console.log(directoryName(plugin, env.version));
}
