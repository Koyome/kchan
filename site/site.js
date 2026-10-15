/* ══════════════════════════════════════════════════════════════════════
   K酱 官网 · 行为
   方向：product-performs —— 页面上的东西要真的会动、真的有用

   四件事：
     1. 首屏放送表：七个星期可翻，真实数据（本季 100 部）
     2. 滚动入场：每段的标题 / 正文 / 片段依次进场
     3. 线路切换片段：进视口后真的跑一遍「超时 → 403 → 成功」
     4. 下载按钮：查最新版本号与体积，失败就回退写死的地址
   ══════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var DATA = window.KCHAN_DATA || { season: '', days: [] };

  /* ── 1. 放送表 ────────────────────────────────────────────────────── */
  var listEl = document.getElementById('sched-list');
  var countEl = document.getElementById('day-count');
  var labelEl = document.getElementById('season-label');
  var dayBtns = Array.prototype.slice.call(
    document.querySelectorAll('.sched-days button'));

  function renderDay(w) {
    var day = null;
    for (var i = 0; i < DATA.days.length; i++) {
      if (DATA.days[i].w === w) { day = DATA.days[i]; break; }
    }
    if (!day) return;

    if (countEl) countEl.textContent = day.shows.length;

    var html = '';
    for (var j = 0; j < day.shows.length; j++) {
      var s = day.shows[j];
      var score = (s.s !== null && s.s !== undefined) ? s.s.toFixed(1) : '';
      var eps = s.e ? ('全 ' + s.e + ' 集') : '';
      html += '<li style="animation-delay:' + (j * 22) + 'ms">' +
        '<span class="nm">' + esc(s.n) + '</span>' +
        '<span class="sc">' + score + '</span>' +
        '<span class="ep">' + eps + '</span>' +
        '</li>';
    }
    if (!html) {
      html = '<li class="sched-empty">这一天没有在播的番剧。</li>';
    }
    listEl.innerHTML = html;
  }

  function esc(t) {
    return String(t).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  function selectDay(w) {
    for (var i = 0; i < dayBtns.length; i++) {
      dayBtns[i].setAttribute('aria-selected',
        dayBtns[i].dataset.w === String(w) ? 'true' : 'false');
    }
    renderDay(w);
  }

  if (listEl && DATA.days.length) {
    if (labelEl && DATA.season) labelEl.textContent = DATA.season;

    dayBtns.forEach(function (b) {
      b.addEventListener('click', function () { selectDay(b.dataset.w); });
      // 键盘：左右箭头在星期之间移动，符合 tablist 语义
      b.addEventListener('keydown', function (e) {
        var i = dayBtns.indexOf(b);
        var n = -1;
        if (e.key === 'ArrowRight') n = (i + 1) % dayBtns.length;
        if (e.key === 'ArrowLeft') n = (i - 1 + dayBtns.length) % dayBtns.length;
        if (n >= 0) { dayBtns[n].focus(); selectDay(dayBtns[n].dataset.w); e.preventDefault(); }
      });
    });

    // 默认选中今天（真实日期，不是写死的）
    var today = new Date().getDay(); // 0=周日
    selectDay(today === 0 ? 7 : today);
  }

  /* ── 2. 滚动入场 ──────────────────────────────────────────────────── */
  var reveals = Array.prototype.slice.call(document.querySelectorAll('.reveal'));

  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (!en.isIntersecting) return;
        var el = en.target;
        // 同一容器内的兄弟依次错开 70ms，不是整块一起淡入
        var sibs = Array.prototype.slice.call(
          el.parentElement ? el.parentElement.querySelectorAll(':scope > .reveal') : []);
        var idx = sibs.indexOf(el);
        var delay = (idx > 0 ? idx * 70 : 0);
        setTimeout(function () { el.classList.add('in'); }, delay);
        io.unobserve(el);
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add('in'); });
  }

  /* ── 3. 线路切换片段：进视口真的跑一遍 ───────────────────────────── */
  var swList = document.querySelector('.switch-list');
  var swShot = document.getElementById('switch-shot');
  var swSum = document.getElementById('switch-sum');
  var swItems = swList ? Array.prototype.slice.call(swList.children) : [];

  function runSwitch() {
    if (!swItems.length) return;
    swItems.forEach(function (li) { li.classList.remove('on'); });
    if (swShot) swShot.classList.remove('on');
    if (swSum) swSum.textContent = '尝试中…';

    swItems.forEach(function (li, i) {
      setTimeout(function () {
        li.classList.add('on');
        if (i === swItems.length - 1) {
          if (swShot) swShot.classList.add('on');
          if (swSum) swSum.textContent = '第 3 条成功';
        }
      }, i * 900);
    });
  }

  if (swList && 'IntersectionObserver' in window) {
    var swIo = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { runSwitch(); swIo.disconnect(); }
      });
    }, { threshold: 0.4 });
    swIo.observe(swList);
  } else {
    runSwitch();
  }

  /* ── 4. 线路体检计数（让片段有个真实的小结论）───────────────────── */
  var probeSum = document.getElementById('probe-sum');
  if (probeSum) {
    var okN = document.querySelectorAll('.probe-list .pst.ok').length;
    var allN = document.querySelectorAll('.probe-list li').length;
    probeSum.textContent = okN + ' / ' + allN + ' 可用';
  }

  /* ── 5. 下载按钮：查最新版本，失败回退 ───────────────────────────── */
  // 写死的回退地址（保证按钮永远可用，即使 API 挂了）
  //
  // 走自建反代：GitHub Release 资产实际在 objects.githubusercontent.com，
  // 但入口 github.com 在国内间歇性被墙（实测 TCP 超时）。Worker 代取可绕开。
  var FALLBACK = '/dl/Koyome/kchan/v2.1.10/Kchan-Windows-v2.1.10.zip';

  // GitHub 原始地址：反代不可用时的第二选择（用户也能自己在页面看到）
  var GH = 'https://github.com/Koyome/kchan/releases/download/v2.1.10/Kchan-Windows-v2.1.10.zip';
  var dlWin = document.getElementById('dl-win');   // 首屏按钮 → 滚到下载区
  var dlBig = document.getElementById('dl-big');   // 下载区按钮 → 真实文件

  if (dlBig) dlBig.href = FALLBACK;
  if (dlWin) {
    dlWin.addEventListener('click', function (e) {
      e.preventDefault();
      var t = document.getElementById('download');
      if (t) t.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  }

  // 异步问 GitHub 要最新 release 的真实资产名与体积（可选增强，失败无所谓）
  if (window.fetch && dlBig) {
    fetch('https://api.github.com/repos/Koyome/kchan/releases/latest', {
      headers: { 'Accept': 'application/vnd.github+json' }
    }).then(function (r) {
      return r.ok ? r.json() : null;
    }).then(function (rel) {
      if (!rel || !rel.assets || !rel.assets.length) return;
      // 优先找 Windows 的 zip
      var pick = null;
      for (var i = 0; i < rel.assets.length; i++) {
        var a = rel.assets[i];
        if (/\.zip$/i.test(a.name) && /win/i.test(a.name)) { pick = a; break; }
      }
      if (!pick) pick = rel.assets[0];
      dlBig.href = pick.browser_download_url;

      var mb = (pick.size / 1024 / 1024).toFixed(0) + ' MB';
      var tag = (rel.tag_name || '').replace(/^v/i, '');
      var meta = dlBig.querySelector('.btn-meta');
      if (meta && tag) meta.textContent = 'v' + tag + ' · ' + mb;
      var note = document.querySelector('.cta > p');
      if (note && tag) note.textContent = 'v' + tag + ' · ' + mb + ' · 解压即用';
    }).catch(function () { /* 保持回退地址，不打扰用户 */ });
  }

  /* ── 6. 无 JS 兜底：脚本没跑起来也要能看到内容 ──────────────────── */
  document.documentElement.classList.remove('no-js');
})();
