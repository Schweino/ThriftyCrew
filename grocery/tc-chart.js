/* tc-chart.js - shared interactive price-history line chart (board popup + trend pages).
   tcChart(containerEl, data) where data = { u:'lb', w:['07-05',...], s:{ 'Store':[2.89,null,...] } }.
   Renders: toggleable store legend (all ON by default; tap a store to hide/show its line; the
   Y axis re-fits to whatever is visible) + multi-line SVG with dots and native tooltips.
   ES5 only. Inlined into pages by build-deals-page.ps1 and build-trend-pages.ps1. */
function tcChart(root, d){
  var COLORS = {"Baker's":'#2f6bb0','Walmart':'#E2A43C','Aldi':'#1f7a4d','Hy-Vee':'#b23b2e','Family Fare':'#7c5cbf',"Sam's Club":'#8a6d1f'};
  var FALLBACK = ['#16263F','#c2703e','#3e8ea1','#946bb0','#6b7f3e','#a14e63'];
  function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
  function fmt(v){ return v < 1 ? '$' + v.toFixed(3) : '$' + v.toFixed(2); }
  var stores = [], fi = 0;
  for (var sn in d.s){
    var arr = d.s[sn], last = null;
    for (var k = arr.length - 1; k >= 0; k--){ if (arr[k] !== null){ last = arr[k]; break; } }
    if (last === null) continue;
    var col = COLORS[sn]; if (!col){ col = FALLBACK[fi % FALLBACK.length]; fi++; }
    stores.push({ n: sn, a: arr, last: last, c: col, on: true });
  }
  stores.sort(function(a,b){ return a.last - b.last; });
  var chartBox = document.createElement('div');
  var legBox = document.createElement('div');
  legBox.className = 'tcc-leg';
  root.appendChild(chartBox);
  root.appendChild(legBox);

  function render(){
    var act = [], i;
    for (i = 0; i < stores.length; i++) if (stores[i].on) act.push(stores[i]);
    if (!act.length){
      chartBox.innerHTML = '<p class="tcc-none">Tap a store below to show its line.</p>';
      renderLegend();
      return;
    }
    var n = d.w.length, ymin = null, ymax = null, s2, w, v;
    for (s2 = 0; s2 < act.length; s2++) for (w = 0; w < n; w++){ v = act[s2].a[w]; if (v !== null){ if (ymin === null || v < ymin) ymin = v; if (ymax === null || v > ymax) ymax = v; } }
    var pad = (ymax - ymin) * 0.1; if (pad <= 0) pad = Math.max(0.05, ymax * 0.05);
    ymin -= pad; ymax += pad; if (ymin < 0) ymin = 0;
    var W = 560, H = 280, L = 50, R = 12, T = 12, B = 34, pw = W - L - R, ph = H - T - B;
    function X(i2){ return n > 1 ? L + i2 * (pw / (n - 1)) : L + pw / 2; }
    function Y(v2){ return T + (ymax - v2) / (ymax - ymin) * ph; }
    var svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Price history chart" style="width:100%;height:auto;display:block">';
    for (var g = 0; g <= 3; g++){
      var gv = ymin + (ymax - ymin) * g / 3, gy = Y(gv);
      svg += '<line x1="' + L + '" y1="' + gy.toFixed(1) + '" x2="' + (W - R) + '" y2="' + gy.toFixed(1) + '" stroke="#eef1f5" stroke-width="1"/>';
      svg += '<text x="' + (L - 6) + '" y="' + (gy + 3.5).toFixed(1) + '" text-anchor="end" font-size="10.5" fill="#8a94a6">' + fmt(gv) + '</text>';
    }
    var step = Math.max(1, Math.ceil(n / 6));
    for (w = 0; w < n; w++){
      if (w % step !== 0 && w !== n - 1) continue;
      svg += '<text x="' + X(w).toFixed(1) + '" y="' + (H - 10) + '" text-anchor="middle" font-size="10.5" fill="#8a94a6">' + esc(d.w[w]) + '</text>';
    }
    for (s2 = 0; s2 < act.length; s2++){
      var st = act[s2], path = '', run = false;
      for (w = 0; w < n; w++){
        v = st.a[w];
        if (v === null){ run = false; continue; }
        path += (run ? 'L' : 'M') + X(w).toFixed(1) + ' ' + Y(v).toFixed(1) + ' ';
        run = true;
      }
      if (path) svg += '<path d="' + path + '" fill="none" stroke="' + st.c + '" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round" opacity=".9"/>';
      for (w = 0; w < n; w++){
        v = st.a[w];
        if (v === null) continue;
        svg += '<circle cx="' + X(w).toFixed(1) + '" cy="' + Y(v).toFixed(1) + '" r="3" fill="' + st.c + '"><title>' + esc(st.n) + ' ' + esc(d.w[w]) + ': ' + fmt(v) + '</title></circle>';
      }
    }
    svg += '</svg>';
    chartBox.innerHTML = svg;
    renderLegend();
  }
  function renderLegend(){
    var h = '';
    for (var i = 0; i < stores.length; i++){
      var st = stores[i];
      h += '<button type="button" class="tcc-chip' + (st.on ? '' : ' is-off') + '" data-i="' + i + '" aria-pressed="' + (st.on ? 'true' : 'false') + '" title="Tap to ' + (st.on ? 'hide' : 'show') + ' this store"><i style="background:' + st.c + '"></i>' + esc(st.n) + '</button>';
    }
    legBox.innerHTML = h;
  }
  legBox.addEventListener('click', function(e){
    var b = e.target.closest ? e.target.closest('.tcc-chip') : null;
    if (!b){ var t = e.target; while (t && t !== legBox){ if (t.className && String(t.className).indexOf('tcc-chip') >= 0){ b = t; break; } t = t.parentNode; } }
    if (!b) return;
    var st = stores[parseInt(b.getAttribute('data-i'), 10)];
    st.on = !st.on;
    render();
  });
  render();
}
