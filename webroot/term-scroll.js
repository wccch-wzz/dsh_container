/* term-scroll.js — xterm 在触摸屏上的滚动、选词、系统复制
 *
 * 1) 按行滚动
 *    不用浏览器原生滚动：.xterm-viewport 是像素级滚动容器，而终端内容只能整行渲染。
 *    WebView 里带惯性的像素滚动会和 canvas 重绘打架（拖动发飘、松手滑过头、位置与行对不齐）。
 *    这里接管手势，按「行」滚动，自己算惯性衰减，并给出滚动位置指示条。
 *
 * 2) 选词
 *    接管手势后（touch-action:none + preventDefault）浏览器和 xterm 自己的长按选词都没了，
 *    所以长按 450ms 进入选择模式，拖动扩展选区，松手弹工具条。
 *
 * 3) 系统复制
 *    xterm 把字符画在 canvas 上，WebView 里没有可选中的 DOM 文本，所以「长按弹系统菜单」
 *    这件事在终端画面里根本无从触发。真正能唤起系统选词/复制菜单的办法是给用户一段真实
 *    文本：attachTermSelection() 的「系统选择」视图就是把缓冲区文本放进一个 <pre>，
 *    在那个视图里长按即系统手柄 + 复制菜单，复制走系统剪贴板。
 *
 * 用法：
 *   var sel = attachTermSelection(term, { host: element, maxLines: 3000 });
 *   var scroller = attachTouchScroll(term, { indicator: el, selection: sel.ctl });
 */
(function (global) {
  'use strict';

  var LONG_PRESS_MS = 450;
  var DRAG_SLOP = 6;

  // ---------------------------------------------------------------- utilities

  function cellSize(term) {
    var fs = 12, ff = 'monospace', lh = 1.15;
    try {
      if (term.options.fontSize) fs = term.options.fontSize;
      if (term.options.fontFamily) ff = term.options.fontFamily;
      if (term.options.lineHeight) lh = term.options.lineHeight;
    } catch (e) {}
    try {
      var d = term._core._renderService.dimensions;
      if (d && d.css && d.css.cell && d.css.cell.width > 0) {
        return { w: d.css.cell.width, h: d.css.cell.height };
      }
    } catch (e) {}
    var span = document.createElement('span');
    span.style.cssText = 'position:absolute;left:-9999px;visibility:hidden;white-space:pre;' +
      'font-family:' + ff + ';font-size:' + fs + 'px;line-height:' + lh;
    span.textContent = 'W'.repeat(32);
    document.body.appendChild(span);
    var w = span.getBoundingClientRect().width / 32;
    document.body.removeChild(span);
    return { w: w || fs * 0.6, h: Math.ceil(fs * lh) };
  }

  function point(e) {
    var t = (e.touches && e.touches[0]) ||
            (e.changedTouches && e.changedTouches[0]) || e;
    return { x: t.clientX, y: t.clientY };
  }

  function clampNum(v, a, b) { return v < a ? a : (v > b ? b : v); }

  // 缓冲区纯文本；trim 掉每行尾随空格，避免复制出一堆空白
  function bufferText(term, maxLines) {
    var b = term.buffer.active, out = [];
    var start = 0;
    if (maxLines && b.length > maxLines) start = b.length - maxLines;
    for (var i = start; i < b.length; i++) {
      var line = b.getLine(i);
      out.push(line ? line.translateToString(true) : '');
    }
    while (out.length && out[out.length - 1] === '') out.pop();
    return out.join('\n');
  }

  function legacyCopy(text) {
    try {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, text.length);
      var ok = document.execCommand('copy');
      document.body.removeChild(ta);
      return ok;
    } catch (e) { return false; }
  }

  function copyText(text, done) {
    text = text || '';
    if (!text) { if (done) done(false, 0); return; }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { if (done) done(true, text.length); },
        function () { if (done) done(legacyCopy(text), text.length); }
      );
    } else {
      if (done) done(legacyCopy(text), text.length);
    }
  }

  // ------------------------------------------------------------- scroll only

  function attachTouchScroll(term, opts) {
    opts = opts || {};
    var el = term.element;
    if (!el) return null;
    var screen = el.querySelector('.xterm-screen') || el;
    var indicator = opts.indicator || null;
    var thumb = indicator ? indicator.querySelector('.thumb') : null;
    var sel = opts.selection || null;
    var hideTimer = 0;

    var st = {
      down: false, moved: false, selecting: false, lp: 0,
      y0: 0, x0: 0, t0: 0, y1: 0, t1: 0, vy: 0, acc: 0, raf: 0
    };

    function maxY() { return term.buffer.active.baseY; }
    function curY() { return term.buffer.active.viewportY; }

    function scrollTo(y) {
      var t = Math.max(0, Math.min(maxY(), y));
      if (t !== curY()) term.scrollToLine(t);
    }

    function flashIndicator() {
      if (!indicator || !thumb) return;
      var total = Math.max(1, maxY() + term.rows);
      var ratio = Math.min(1, term.rows / total);
      var h = Math.max(10, Math.round(indicator.clientHeight * ratio));
      thumb.style.height = h + 'px';
      var span = Math.max(0, indicator.clientHeight - h);
      var p = maxY() > 0 ? curY() / maxY() : 1;
      thumb.style.transform = 'translateY(' + Math.round(span * p) + 'px)';
      indicator.classList.add('show');
      clearTimeout(hideTimer);
      hideTimer = setTimeout(function () { indicator.classList.remove('show'); }, 900);
    }

    function stopFling() {
      if (st.raf) { cancelAnimationFrame(st.raf); st.raf = 0; }
      st.vy = 0;
      st.acc = 0;
    }

    function fling() {
      st.raf = 0;
      var h = cellSize(term).h;
      st.acc += st.vy * 16;                 // 每帧位移（px）
      var whole = st.acc / h;
      var lines = whole < 0 ? Math.ceil(whole) : Math.floor(whole);
      if (lines) {
        st.acc -= lines * h;
        scrollTo(curY() - lines);
      }
      st.vy *= 0.94;
      var atEdge = (curY() <= 0 && st.vy > 0) || (curY() >= maxY() && st.vy < 0);
      if (Math.abs(st.vy) > 0.02 && !atEdge) {
        st.raf = requestAnimationFrame(fling);
      } else {
        st.vy = 0;
        st.acc = 0;
      }
      flashIndicator();
    }

    function cancelLongPress() {
      if (st.lp) { clearTimeout(st.lp); st.lp = 0; }
    }

    function onStart(e) {
      if (e.touches && e.touches.length > 1) {
        st.down = false;
        cancelLongPress();
        return;
      }
      var p = point(e);
      stopFling();
      st.down = true;
      st.moved = false;
      st.selecting = false;
      st.x0 = p.x;
      st.y0 = st.y1 = p.y;
      st.t0 = st.t1 = Date.now();
      st.vy = 0;
      st.acc = 0;
      cancelLongPress();

      if (!sel) return;
      if (sel.active()) {
        st.selecting = true;
        sel.extend(p.x, p.y);
        return;
      }
      st.lp = setTimeout(function () {
        st.lp = 0;
        if (!st.down || st.moved) return;
        st.selecting = true;
        sel.begin(p.x, p.y);
      }, LONG_PRESS_MS);
    }

    function onMove(e) {
      if (!st.down) return;
      var p = point(e);
      var now = Date.now();

      if (!st.selecting && (Math.abs(p.y - st.y0) > DRAG_SLOP || Math.abs(p.x - st.x0) > DRAG_SLOP)) {
        st.moved = true;
        cancelLongPress();
      }

      if (st.selecting) {
        if (e.cancelable) e.preventDefault();
        if (sel) sel.extend(p.x, p.y);
        return;
      }

      var dy = p.y - st.y1;
      var dt = Math.max(1, now - st.t1);
      st.y1 = p.y;
      st.t1 = now;
      if (!st.moved) return;
      if (e.cancelable) e.preventDefault();
      st.vy = dy / dt;
      var h = cellSize(term).h;
      st.acc -= dy;                          // 手指下拉 → 看更早内容 → viewportY 减小
      var whole = st.acc / h;
      var lines = whole < 0 ? Math.ceil(whole) : Math.floor(whole);
      if (lines) {
        st.acc -= lines * h;
        scrollTo(curY() + lines);
      }
      flashIndicator();
    }

    function onEnd() {
      cancelLongPress();
      if (!st.down) return;
      st.down = false;
      if (st.selecting) {
        st.selecting = false;
        if (sel) sel.end();
        return;
      }
      if (st.moved && Math.abs(st.vy) > 0.05) fling();
      st.moved = false;
    }

    screen.addEventListener('touchstart', onStart, { passive: true });
    screen.addEventListener('touchmove', onMove, { passive: false });
    screen.addEventListener('touchend', onEnd, { passive: true });
    screen.addEventListener('touchcancel', onEnd, { passive: true });
    term.onScroll(flashIndicator);

    return {
      detach: function () {
        stopFling();
        cancelLongPress();
        screen.removeEventListener('touchstart', onStart);
        screen.removeEventListener('touchmove', onMove);
        screen.removeEventListener('touchend', onEnd);
        screen.removeEventListener('touchcancel', onEnd);
      },
      scrollToBottom: function () { term.scrollToBottom(); },
      isAtBottom: function () { return curY() >= maxY(); },
      refreshIndicator: flashIndicator
    };
  }

  // -------------------------------------------------- selection + system copy

  var CSS = [
    '.tsel-bar{position:absolute;left:50%;bottom:12px;transform:translateX(-50%);display:none;',
    'gap:8px;background:#18212a;border:1px solid #22303c;border-radius:12px;padding:7px 9px;',
    'box-shadow:0 8px 22px rgba(0,0,0,.55);z-index:30}',
    '.tsel-bar.show{display:flex}',
    '.tsel-bar button{border:1px solid #22303c;background:#1a232c;color:#e8eef4;border-radius:8px;',
    'padding:8px 13px;font-size:13px;line-height:1;font-family:inherit}',
    '.tsel-bar button.primary{background:#4aa3ff;border-color:#4aa3ff;color:#04121f;font-weight:700}',
    '.tsel-bar button:active{transform:scale(.96)}',
    '.tsel-view{position:absolute;inset:0;display:none;flex-direction:column;background:#0b0f13;z-index:40}',
    '.tsel-view.show{display:flex}',
    '.tsel-view-bar{display:flex;align-items:center;gap:8px;padding:6px 8px;background:#111820;',
    'border-bottom:1px solid #22303c;flex:0 0 auto}',
    '.tsel-view-bar button{border:1px solid #22303c;background:#1a232c;color:#e8eef4;border-radius:8px;',
    'padding:7px 12px;font-size:13px;line-height:1;font-family:inherit}',
    '.tsel-view-tip{flex:1;font-size:11px;color:#8fa3b4;text-align:right}',
    '.tsel-view-pre{flex:1 1 auto;min-height:0;margin:0;padding:8px;overflow:auto;',
    'font-family:ui-monospace,Menlo,Consolas,"Noto Sans Mono",monospace;font-size:12px;',
    'line-height:1.35;color:#cfd8e3;white-space:pre;-webkit-user-select:text;user-select:text;',
    '-webkit-overflow-scrolling:touch;overscroll-behavior:contain;touch-action:pan-y}',
    '.tsel-toast{position:absolute;left:50%;bottom:70px;transform:translateX(-50%);',
    'background:#22303c;border:1px solid #22303c;color:#e8eef4;padding:8px 15px;border-radius:10px;',
    'font-size:12px;opacity:0;transition:opacity .18s;pointer-events:none;z-index:50}',
    '.tsel-toast.show{opacity:1}'
  ].join('');

  function injectCss() {
    if (document.getElementById('tsel-css')) return;
    var s = document.createElement('style');
    s.id = 'tsel-css';
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  }

  /**
   * opts.host     必填，position:relative 的容器（终端所在区域）
   * opts.maxLines 系统选择视图最多显示多少行（默认 3000）
   * opts.onToast  自定义提示（可选）
   */
  function attachTermSelection(term, opts) {
    opts = opts || {};
    injectCss();
    var host = opts.host;
    if (!host) return null;
    var maxLines = opts.maxLines || 3000;

    function toast(msg) {
      if (typeof opts.onToast === 'function') { opts.onToast(msg); return; }
      var el = host.querySelector('.tsel-toast');
      if (!el) {
        el = document.createElement('div');
        el.className = 'tsel-toast';
        host.appendChild(el);
      }
      el.textContent = msg;
      el.classList.add('show');
      clearTimeout(toast._t);
      toast._t = setTimeout(function () { el.classList.remove('show'); }, 1800);
    }

    // ---- 工具条 ----
    var bar = document.createElement('div');
    bar.className = 'tsel-bar';
    bar.innerHTML =
      '<button data-a="copy" class="primary">复制</button>' +
      '<button data-a="all">全选</button>' +
      '<button data-a="text">系统选择</button>' +
      '<button data-a="cancel">取消</button>';
    host.appendChild(bar);

    // ---- 系统选择视图（真实 DOM 文本，长按即系统选词/复制菜单）----
    var view = document.createElement('div');
    view.className = 'tsel-view';
    view.innerHTML =
      '<div class="tsel-view-bar">' +
        '<button data-a="back">← 返回终端</button>' +
        '<span class="tsel-view-tip">长按文字可用系统复制</span>' +
      '</div>' +
      '<pre class="tsel-view-pre"></pre>';
    host.appendChild(view);
    var pre = view.querySelector('.tsel-view-pre');

    var selOn = false;
    var anchor = null;

    function cellAt(x, y) {
      var el = term.element;
      if (!el) return null;
      var r = el.getBoundingClientRect(), c = cellSize(term);
      var col = clampNum(Math.floor((x - r.left) / c.w), 0, term.cols - 1);
      var row = clampNum(Math.floor((y - r.top) / c.h), 0, term.rows - 1);
      return { col: col, abs: term.buffer.active.viewportY + row };
    }

    function applySel(a, b) {
      var s = a, e = b;
      if (e.abs < s.abs || (e.abs === s.abs && e.col < s.col)) { s = b; e = a; }
      var len = (e.abs - s.abs) * term.cols + (e.col - s.col) + 1;
      if (len < 1) len = 1;
      term.select(s.col, s.abs, len);
    }

    function hasSel() {
      try { return !!term.getSelection(); } catch (e) { return false; }
    }

    function syncBar() {
      bar.classList.toggle('show', hasSel() && !view.classList.contains('show'));
    }

    function clearSel() {
      selOn = false;
      anchor = null;
      try { term.clearSelection(); } catch (e) {}
      bar.classList.remove('show');
    }

    function copySelection() {
      var t = '';
      try { t = term.getSelection(); } catch (e) {}
      if (!t) { toast('没有选中内容（长按终端可选中）'); return; }
      copyText(t, function (ok, n) {
        toast(ok ? ('已复制 ' + n + ' 字到系统剪贴板') : '复制失败');
        if (ok) clearSel();
      });
    }

    function copyAll() {
      var t = bufferText(term, maxLines);
      if (!t) { toast('没有可复制的内容'); return; }
      copyText(t, function (ok, n) {
        toast(ok ? ('已复制全部 ' + n + ' 字到系统剪贴板') : '复制失败');
      });
    }

    function showTextView() {
      pre.textContent = bufferText(term, maxLines) || '(暂无输出)';
      view.classList.add('show');
      bar.classList.remove('show');
      pre.scrollTop = pre.scrollHeight;
    }

    function hideTextView() {
      view.classList.remove('show');
      try { term.focus(); } catch (e) {}
      syncBar();
    }

    bar.addEventListener('click', function (ev) {
      var a = ev.target && ev.target.getAttribute('data-a');
      if (!a) return;
      ev.preventDefault();
      ev.stopPropagation();
      if (a === 'copy') copySelection();
      else if (a === 'all') { try { term.selectAll(); } catch (e) {} syncBar(); }
      else if (a === 'text') showTextView();
      else if (a === 'cancel') clearSel();
    });

    view.addEventListener('click', function (ev) {
      var a = ev.target && ev.target.getAttribute('data-a');
      if (a === 'back') { ev.preventDefault(); hideTextView(); }
    });

    term.onSelectionChange(syncBar);

    return {
      ctl: {
        active: function () { return selOn; },
        begin: function (x, y) {
          var c = cellAt(x, y);
          if (!c) return;
          selOn = true;
          anchor = c;
          try { term.select(c.col, c.abs, 1); } catch (e) {}
          syncBar();
        },
        extend: function (x, y) {
          if (!selOn || !anchor) return;
          var c = cellAt(x, y);
          if (!c) return;
          applySel(anchor, c);
        },
        end: function () {
          if (!selOn) return;
          if (hasSel()) syncBar(); else clearSel();
        }
      },
      copySelection: copySelection,
      copyAll: copyAll,
      showTextView: showTextView,
      hideTextView: hideTextView,
      clearSelection: clearSel,
      toast: toast,
      isTextViewOpen: function () { return view.classList.contains('show'); }
    };
  }

  global.attachTouchScroll = attachTouchScroll;
  global.attachTermSelection = attachTermSelection;
  global.termBufferText = bufferText;
})(window);
