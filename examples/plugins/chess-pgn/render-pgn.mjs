let input = "";
for await (const chunk of process.stdin) input += chunk;
const invocation = JSON.parse(input);
const pgn = String(invocation?.block?.body || "").trim();

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function parsePGN(source) {
  const headers = {};
  for (const match of source.matchAll(/^\s*\[([A-Za-z0-9_]+)\s+"((?:\\.|[^"])*)"\]\s*$/gm)) {
    headers[match[1]] = match[2].replace(/\\"/g, '"');
  }
  let movesText = source
    .replace(/^\s*\[[^\n]*\]\s*$/gm, " ")
    .replace(/;[^\n]*/g, " ")
    .replace(/\{[^}]*\}/gs, " ");
  let depth = 0;
  movesText = [...movesText].map((character) => {
    if (character === "(") { depth += 1; return " "; }
    if (character === ")") { depth = Math.max(0, depth - 1); return " "; }
    return depth ? " " : character;
  }).join("");
  const moves = movesText
    .replace(/\$\d+/g, " ")
    .split(/\s+/)
    .map((token) => token.replace(/^\d+\.(?:\.\.)?/, ""))
    .filter((token) => token && !/^\d+\.{1,3}$/.test(token) && !/^(?:1-0|0-1|1\/2-1\/2|\*)$/.test(token));
  return { headers, moves };
}

const game = parsePGN(pgn);
const title = game.headers.Event || [game.headers.White, game.headers.Black].filter(Boolean).join(" – ") || "Chess game";
const subtitle = [game.headers.White, game.headers.Black].filter(Boolean).join(" vs. ");
const moveButtons = game.moves.map((move, index) => `<button type="button" class="move" data-ply="${index + 1}"><span>${Math.floor(index / 2) + 1}${index % 2 ? "…" : "."}</span>${escapeHtml(move)}</button>`).join("");
const model = JSON.stringify(game).replace(/</g, "\\u003c");

const html = `<section class="chess-card">
  <header><div><h1>${escapeHtml(title)}</h1>${subtitle ? `<p>${escapeHtml(subtitle)}</p>` : ""}</div><output id="position-label">Start position</output></header>
  <div class="layout">
    <div id="board" class="board" role="grid" aria-label="Chess position"></div>
    <div class="side">
      <div class="controls"><button id="previous" type="button" aria-label="Previous move">←</button><button id="next" type="button" aria-label="Next move">→</button></div>
      <div id="moves" class="moves" aria-label="Game moves">${moveButtons || "<p>No moves found in this PGN.</p>"}</div>
    </div>
  </div>
</section>`;

const css = `
:root{--light:#f0d9b5;--dark:#b58863;--accent:#3478d4;--panel:color-mix(in srgb,Canvas 92%,CanvasText 8%)}
body{color:CanvasText;background:transparent}
.chess-card{padding:12px;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:14px;background:var(--panel)}
header{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;margin:0 0 10px}
h1{font-size:18px;line-height:1.2;margin:0} header p{font-size:13px;opacity:.66;margin:3px 0 0} output{font-size:12px;opacity:.68}
.layout{display:grid;grid-template-columns:minmax(280px,520px) minmax(180px,1fr);gap:14px;align-items:start}
.board{display:grid;grid-template-columns:repeat(8,1fr);aspect-ratio:1;overflow:hidden;border-radius:8px;box-shadow:0 2px 8px #0003}
.square{display:grid;place-items:center;position:relative;font-size:clamp(22px,6vw,48px);line-height:1;user-select:none}.square.light{background:var(--light)}.square.dark{background:var(--dark)}
.square::after{content:attr(data-label);position:absolute;right:3px;bottom:2px;font:600 9px/1 ui-monospace,monospace;opacity:.48;color:#22170e}.square.dark::after{color:#fff7e9}
.side{min-width:0}.controls{display:flex;gap:6px;margin-bottom:8px}.controls button{width:36px;height:30px;border:1px solid #8886;border-radius:7px;background:Canvas;color:CanvasText;cursor:pointer}.controls button:disabled{opacity:.35}
.moves{display:flex;flex-wrap:wrap;align-content:flex-start;gap:4px;max-height:440px;overflow:auto}.move{display:inline-flex;gap:4px;padding:4px 6px;border:0;border-radius:6px;background:transparent;color:CanvasText;font:13px/1.25 ui-monospace,monospace;cursor:pointer}.move span{opacity:.45}.move:hover{background:#8882}.move.active{color:white;background:var(--accent)}
@media(max-width:640px){.layout{grid-template-columns:1fr}.moves{max-height:150px}}
`;

const script = `
const model=${model};
const glyph={wK:"♔",wQ:"♕",wR:"♖",wB:"♗",wN:"♘",wP:"♙",bK:"♚",bQ:"♛",bR:"♜",bB:"♝",bN:"♞",bP:"♟"};
const files="abcdefgh";
function initial(){const b={};for(let i=0;i<8;i++){b[files[i]+"2"]="wP";b[files[i]+"7"]="bP"}for(const [i,p] of [..."RNBQKBNR"].entries()){b[files[i]+"1"]="w"+p;b[files[i]+"8"]="b"+p}return b}
function xy(square){return [files.indexOf(square[0]),Number(square[1])-1]}
function clearPath(board,from,to){const [fx,fy]=xy(from),[tx,ty]=xy(to),dx=Math.sign(tx-fx),dy=Math.sign(ty-fy);let x=fx+dx,y=fy+dy;while(x!==tx||y!==ty){if(board[files[x]+(y+1)])return false;x+=dx;y+=dy}return true}
function canMove(board,from,to,piece,capture,color){const [fx,fy]=xy(from),[tx,ty]=xy(to),dx=tx-fx,dy=ty-fy,adX=Math.abs(dx),adY=Math.abs(dy);if(piece==="N")return adX*adY===2;if(piece==="B")return adX===adY&&clearPath(board,from,to);if(piece==="R")return (dx===0||dy===0)&&clearPath(board,from,to);if(piece==="Q")return (dx===0||dy===0||adX===adY)&&clearPath(board,from,to);if(piece==="K")return Math.max(adX,adY)===1;const direction=color==="w"?1:-1;const start=color==="w"?1:6;if(capture)return adX===1&&dy===direction;if(dx!==0)return false;if(dy===direction)return !board[to];if(fy===start&&dy===2*direction)return !board[to]&&!board[files[fx]+(fy+direction+1)];return false}
function apply(board,san,ply){const next={...board},color=ply%2===0?"w":"b";let token=san.replace(/[+#?!]+$/g,"");if(/^O-O(?:-O)?$/.test(token)){const long=token==="O-O-O",rank=color==="w"?"1":"8",kingFrom="e"+rank,kingTo=(long?"c":"g")+rank,rookFrom=(long?"a":"h")+rank,rookTo=(long?"d":"f")+rank;next[kingTo]=next[kingFrom];delete next[kingFrom];next[rookTo]=next[rookFrom];delete next[rookFrom];return next}const promotion=(token.match(/=([QRBN])/)||[])[1];token=token.replace(/=[QRBN]/,"");const destination=(token.match(/([a-h][1-8])$/)||[])[1];if(!destination)return next;const piece=/^[KQRBN]/.test(token)?token[0]:"P",capture=token.includes("x");let middle=token.slice(piece==="P"?0:1,token.length-2).replace("x","");const origins=Object.keys(next).filter((square)=>next[square]===color+piece&&canMove(next,square,destination,piece,capture,color)&&(!middle||middle.includes(square[0])||middle.includes(square[1])));const from=origins[0];if(!from)return next;if(piece==="P"&&capture&&!next[destination]){const [tx,ty]=xy(destination);delete next[files[tx]+(ty+(color==="w"?-1:1)+1)]}delete next[from];next[destination]=color+(promotion||piece);return next}
const positions=[initial()];model.moves.forEach((move,index)=>positions.push(apply(positions[index],move,index)));
const board=document.getElementById("board"),label=document.getElementById("position-label"),previous=document.getElementById("previous"),next=document.getElementById("next");let ply=0;
function render(){board.replaceChildren();for(let rank=8;rank>=1;rank--)for(let file=0;file<8;file++){const square=files[file]+rank,cell=document.createElement("div");cell.className="square "+((file+rank)%2?"light":"dark");cell.dataset.label=(file===7?square:"");cell.setAttribute("role","gridcell");cell.textContent=glyph[positions[ply][square]]||"";board.append(cell)}document.querySelectorAll(".move").forEach((button)=>button.classList.toggle("active",Number(button.dataset.ply)===ply));label.textContent=ply?((Math.floor((ply-1)/2)+1)+(ply%2?". ":"… ")+model.moves[ply-1]):"Start position";previous.disabled=ply===0;next.disabled=ply===model.moves.length}
previous.addEventListener("click",()=>{ply=Math.max(0,ply-1);render()});next.addEventListener("click",()=>{ply=Math.min(model.moves.length,ply+1);render()});document.getElementById("moves").addEventListener("click",event=>{const button=event.target.closest("[data-ply]");if(button){ply=Number(button.dataset.ply);render()}});render();
`;

process.stdout.write(JSON.stringify({
  $schema: "org2:plugin-render-result:v1",
  html,
  css,
  script,
  title,
  height: 610
}));
