// 端末に出たファイルのパスを Cmd+クリックしたら、そのタブの herdr-nvim の nvim で開く。
import { appHome, exec } from "herdr";

// nvim で読めないものは "pass" して、herdr-nvim のプレビューか OS のアプリに任せる。
const NOT_TEXT = /\.(png|jpe?g|gif|webp|bmp|ico|icns|heic|tiff?|pdf|mp4|mov|webm|mp3|wav|zip|gz|tgz|dmg|app)$/i;

export async function handleLink({ link, source }) {
  const path = link.path;
  if (!path || NOT_TEXT.test(path) || !source?.tab) return "pass";
  const isFile = await exec("test", ["-f", path]).then((r) => r.code === 0, () => false);
  if (!isFile) return "pass";

  const target = [path, link.line, link.line && link.column].filter(Boolean).join(":");
  const bin = `${appHome()}/mods/herdr-nvim/bin/herdr-nvim`;
  // herdr-nvim が無い・失敗したときも "pass" して、この mod が無いときと同じ開き方に任せる。
  const r = await exec(bin, ["open", "--tab", source.tab, target]).catch(() => null);
  return r?.code === 0 ? "handled" : "pass";
}
