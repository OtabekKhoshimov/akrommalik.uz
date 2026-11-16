(function () {
  // ---------- Kirill → Lotin (o'zbek imlosi) ----------
  var MAP = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ё": "yo", "ж": "j", "з": "z", "и": "i",
    "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s",
    "т": "t", "у": "u", "ф": "f", "х": "x", "ц": "s", "ч": "ch", "ш": "sh", "щ": "sh", "ъ": "ʼ",
    "ы": "i", "ь": "", "э": "e", "ю": "yu", "я": "ya", "ў": "oʻ", "қ": "q", "ғ": "gʻ", "ҳ": "h"
  };
  var VOWELS = "аеёиоуэюяўaeiou";
  var isUpper = function (c) { return c !== c.toLowerCase(); };
  var isLetter = function (c) { return !!c && c.toLowerCase() !== c.toUpperCase(); };

  function toLatin(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
      var ch = text[i], lo = ch.toLowerCase(), prev = text[i - 1] || "", next = text[i + 1] || "";
      var t;
      if (lo === "е") {
        var start = !isLetter(prev);
        t = start || VOWELS.indexOf(prev.toLowerCase()) >= 0 || prev.toLowerCase() === "ъ" || prev.toLowerCase() === "ь" ? "ye" : "e";
      } else if (lo === "ц") {
        t = VOWELS.indexOf(prev.toLowerCase()) >= 0 ? "ts" : "s";
      } else if (MAP.hasOwnProperty(lo)) {
        t = MAP[lo];
      } else {
        out += ch;
        continue;
      }
      if (isUpper(ch) && t) {
        var allCaps = (isLetter(next) && isUpper(next)) || (isLetter(prev) && isUpper(prev) && !(isLetter(next) && !isUpper(next)));
        t = allCaps ? t.toUpperCase() : t.charAt(0).toUpperCase() + t.slice(1);
      }
      out += t;
    }
    return out;
  }

  // ---------- Kirill maqolani lotinda o'qish ----------
  var note = document.getElementById("scriptNote");
  var prose = document.querySelector(".prose");
  if (note && prose) {
    note.classList.add("show");
    var btn = note.querySelector("button");
    var saved = [];
    var latin = false;
    function walk(node) {
      if (node.nodeType === 3) { if (/[Ѐ-ӿ]/.test(node.nodeValue)) saved.push([node, node.nodeValue]); return; }
      for (var c = node.firstChild; c; c = c.nextSibling) walk(c);
    }
    var titleEl = document.querySelector(".article h1");
    btn.addEventListener("click", function () {
      if (!saved.length) { walk(prose); if (titleEl) walk(titleEl); }
      latin = !latin;
      saved.forEach(function (s) { s[0].nodeValue = latin ? toLatin(s[1]) : s[1]; });
      btn.textContent = latin ? "Kirillda o‘qish" : "Lotinda o‘qish";
      try { localStorage.setItem("yozuv", latin ? "lotin" : "kiril"); } catch (e) {}
    });
    try { if (localStorage.getItem("yozuv") === "lotin") btn.click(); } catch (e) {}
  }

  // ---------- Mobil menyu ----------
  var menuBtn = document.getElementById("menuBtn");
  if (menuBtn) {
    menuBtn.addEventListener("click", function () {
      var open = document.body.classList.toggle("menu-open");
      menuBtn.setAttribute("aria-expanded", open);
    });
  }

  // ---------- Ro'yxat: qidiruv va "Yana ko'rsatish" ----------
  var cards = document.getElementById("cards");
  if (cards) {
    var items = Array.prototype.slice.call(cards.children);
    var search = document.getElementById("search");
    var more = document.getElementById("more");
    var empty = document.getElementById("empty");
    var PAGE = 18, shown = PAGE;
    var norm = function (s) { return toLatin(s.toLowerCase()).replace(/[ʻʼ'‘’`]/g, "").replace(/ş/g, "sh").replace(/ç/g, "ch").replace(/ğ/g, "g").replace(/ö/g, "o").replace(/ü/g, "u"); };
    var keys = items.map(function (el) { return norm(el.getAttribute("data-search") || ""); });

    function render() {
      var q = search ? norm(search.value.trim()) : "";
      var matches = 0;
      items.forEach(function (el, i) {
        var ok = !q || keys[i].indexOf(q) >= 0;
        if (ok) matches++;
        el.hidden = !ok || (!q && matches > shown);
      });
      if (more) more.hidden = !!q || items.length <= shown;
      if (empty) empty.hidden = matches > 0;
    }
    if (search) search.addEventListener("input", render);
    if (more) more.addEventListener("click", function () { shown += PAGE; render(); });
    render();
  }
})();
