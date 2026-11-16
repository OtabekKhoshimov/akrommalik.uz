# encoding: utf-8
# Telegram kanaldan postlarni olib, saytni qayta quradi.
#
#   ruby tools/sync.rb          # yangi postlarni olish + saytni qurish
#   ruby tools/sync.rb --full   # kanal tarixini boshidan to'liq olish
#   ruby tools/sync.rb --build  # internetga chiqmasdan faqat qurish
#
# Faqat Ruby standart kutubxonasi ishlatiladi (GitHub Actions'da ham, Mac'da ham ishlaydi).

require "net/http"
require "uri"
require "json"
require "fileutils"
require "time"
require "cgi"

ROOT = File.expand_path("..", __dir__)
SITE = JSON.parse(File.read(File.join(ROOT, "data/site.json"), encoding: "UTF-8"))
POSTS_FILE = File.join(ROOT, "data/posts.json")
HIDDEN_FILE = File.join(ROOT, "data/hidden.json")
KINDS_FILE = File.join(ROOT, "data/kinds.json")
TPL_DIR = File.join(ROOT, "tools/templates")
CHANNEL = SITE["telegram"]
MIN_LENGTH = SITE["min_article_length"] || 500

# ---------- Telegram'dan olish ----------

def http_get(url, limit = 5)
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 20, read_timeout: 40) do |h|
    h.get(uri.request_uri, "User-Agent" => "Mozilla/5.0 (site-sync)", "Accept-Language" => "uz,ru;q=0.8")
  end
  if res.is_a?(Net::HTTPRedirection) && limit > 0
    return http_get(URI.join(url, res["location"]).to_s, limit - 1)
  end
  raise "HTTP #{res.code} #{url}" unless res.is_a?(Net::HTTPSuccess)
  res.body.force_encoding("UTF-8")
end

def decode(s)
  CGI.unescapeHTML(s.gsub("&#33;", "!")).gsub(" ", " ")
end

# Telegram matnidagi HTML'ni xavfsiz, sodda HTML'ga aylantiradi.
def clean_html(raw)
  h = raw.dup
  h.gsub!(%r{<i class="emoji"[^>]*><b>(.*?)</b></i>}m, '\1')
  h.gsub!(%r{<tg-emoji[^>]*>(.*?)</tg-emoji>}m, '\1')
  h.gsub!(%r{<br\s*/?>}, "\n")
  out = +""
  h.scan(%r{(<[^>]+>)|([^<]+)}m) do |tag, text|
    if text
      out << text
    elsif tag =~ %r{\A<a\s[^>]*href="([^"]+)"}
      href = decode(Regexp.last_match(1))
      out << (href =~ %r{\A(https?:|tg:|mailto:)} ? %(<a href="#{CGI.escapeHTML(href)}" target="_blank" rel="noopener">) : "<a>")
    elsif tag =~ %r{\A<(/?)(b|strong|i|em|u|s|del|code|pre|blockquote)\b[^>]*>\z}
      t = { "strong" => "b", "em" => "i", "del" => "s" }[Regexp.last_match(2)] || Regexp.last_match(2)
      out << "<#{Regexp.last_match(1)}#{t}>"
    elsif tag == "</a>"
      out << "</a>"
    end
  end
  out.gsub("&#33;", "!").gsub("&nbsp;", " ").strip
end

def plain(html)
  decode(html.gsub(/<[^>]+>/, "")).gsub(/[​‌‍﻿]/, "").strip
end

def parse_page(html)
  html.split('class="tgme_widget_message_wrap').drop(1).map do |b|
    id = b[/data-post="[^"\/]+\/(\d+)"/, 1] or next
    raw = b[%r{<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>}m, 1].to_s
    photo = b[/tgme_widget_message_photo_wrap[^>]*background-image:url\('([^']+)'\)/, 1]
    {
      "id" => id.to_i,
      "date" => b[/datetime="([^"]+)"/, 1],
      "html" => clean_html(raw),
      "photo_url" => photo,
      "has_video" => b.include?("tgme_widget_message_video"),
      "fwd" => b.include?("tgme_widget_message_forwarded_from"),
      "views" => b[/tgme_widget_message_views">([^<]*)/, 1],
    }
  end.compact
end

def fetch(full:)
  db = File.exist?(POSTS_FILE) ? JSON.parse(File.read(POSTS_FILE, encoding: "UTF-8")) : []
  by_id = {}
  db.each { |p| by_id[p["id"]] = p }
  url = "https://t.me/s/#{CHANNEL}"
  pages = 0
  loop do
    items = parse_page(http_get(url))
    pages += 1
    break if items.empty?
    fresh = 0
    items.each do |it|
      fresh += 1 unless by_id.key?(it["id"])
      old = by_id[it["id"]] || {}
      by_id[it["id"]] = old.merge(it) { |k, o, n| k == "photo_url" && n.nil? ? o : n }
    end
    min_id = items.map { |i| i["id"] }.min
    break if min_id <= 1 || pages >= 200
    break if !full && fresh.zero?
    url = "https://t.me/s/#{CHANNEL}?before=#{min_id}"
    sleep 0.6
  end
  posts = by_id.values.sort_by { |p| -p["id"] }
  File.write(POSTS_FILE, JSON.pretty_generate(posts) + "\n")
  puts "Telegram: #{pages} sahifa o'qildi, bazada #{posts.size} post."
  posts
end

# ---------- Yordamchi ----------

MONTHS = %w[yanvar fevral mart aprel may iyun iyul avgust sentabr oktabr noyabr dekabr].freeze
MONTHS_RE = /\b(yanvar|fevral|mart|aprel|may|iyun|iyul|avgust|sentabr|sentyabr|oktabr|oktyabr|noyabr|dekabr|январ|феврал|март|апрел|май|июн|июл|август|сентабр|октабр|ноябр|декабр)/i

def uz_date(iso)
  t = Time.parse(iso).getlocal("+05:00")
  "#{t.day}-#{MONTHS[t.month - 1]}, #{t.year}"
end

def truncate(s, n)
  return s if s.length <= n
  cut = s[0, n].sub(/\s+\S*\z/, "")
  cut.sub(/[\s,.;:!?—–-]+\z/, "") + "…"
end

def esc(s)
  CGI.escapeHTML(s.to_s)
end

def views_num(v)
  s = v.to_s.strip
  return 0 if s.empty?
  s =~ /([\d.]+)\s*K/i ? (Regexp.last_match(1).to_f * 1000).to_i : s.to_i
end

def cyrillic?(s)
  cyr = s.count("А-Яа-яЎўҚқҒғҲҳЁё")
  lat = s.count("A-Za-z")
  cyr > lat
end

def youtube_id(html)
  html[%r{(?:youtu\.be/|youtube\.com/(?:watch\?v=|live/|shorts/|embed/))([A-Za-z0-9_-]{11})}, 1]
end

def download_image(post)
  return nil unless post["photo_url"]
  rel = "assets/posts/#{post["id"]}.jpg"
  path = File.join(ROOT, rel)
  unless File.exist?(path)
    begin
      File.binwrite(path, http_get(post["photo_url"]))
    rescue => e
      warn "Rasm yuklanmadi (#{post["id"]}): #{e.message}"
      return nil
    end
  end
  rel
end

# ---------- Tasniflash ----------

CHAPTER_RE = /\A[[:alpha:]‘ʻ'’ʼ\s-]{3,30}\s+bob\z/i
PART_RE = /\A(muqaddima|adoq|xotima|so‘zboshi|soʻzboshi)\z/i
SECTION_RE = /\A[[:alpha:]‘ʻ'’ʼ\s-]{3,24}\s+fasl\z/i
SKIP_HEAD_RE = /\A(assalomu alaykum|ассалому алайкум|👉|boshlanishi|boshi\b|davomi|reklama emas|tavsiya!?\z)/i

def poem?(text)
  lines = text.split("\n").map(&:strip).reject do |l|
    l.empty? || l =~ /\A[\#@👉]/ || l =~ %r{https?://} || l =~ /\A\d+[.)]\s/ ||
      l =~ /\A(akrom\s+malik|акром\s+малик)/i || l =~ /\A\d{1,2}[-\s]?[[:alpha:]]+,?\s*\d{4}/
  end
  return false if lines.size < 6 || lines.first.length > 72
  return false if text =~ /\A\s*(assalomu|ассалому|assalamu|hurmatli)/i
  return false if lines.count { |l| l =~ /\d{1,2}:\d{2}/ } >= 2
  return false if lines.any? { |l| l =~ /\bbob\b/i } || lines.count { |l| l =~ /\A\d+(\.\d+)+/ } >= 2
  good = lines.count { |l| l.length.between?(8, 72) }
  good.to_f / lines.size >= 0.8 && lines.none? { |l| l.length > 120 }
end

def classify(p, text, html, forced)
  return nil if forced == "skip"
  return forced.to_sym if forced
  return :mumtoz_oila if text.include?("#mumtoz_oila")
  if text =~ /\b(ismim|yoshim|yoshdaman|исмим|ёшим)\b/i && text =~ /tahsil|alifbo|kurs|ustoz|таҳсил|алифбо/i && text.length >= 300
    return :taqriz
  end
  yt = youtube_id(html)
  return :video if yt && text.length < 700
  if html.include?("forms.gle") ||
     (text =~ /\b(ariza|qabul|taklif etamiz|taklif qilamiz|premyera|taqdimot|ro‘yxatdan|roʻyxatdan|таклиф|тақдимот|ариза)\b/i &&
      text =~ MONTHS_RE && text.length < 2500)
    return :elon
  end
  return :sher if poem?(text)
  return :maqola if text.length >= MIN_LENGTH
  nil
end

# Harflarning 80% dan ko'pi bosh harf bo'lsa (imlo xatolariga chidamli)
def mostly_upper?(t)
  letters = t.scan(/[[:alpha:]]/)
  letters.size >= 3 && letters.count { |c| c == c.upcase } >= letters.size * 0.8
end

def smart_title(t)
  t = t.gsub(/\s+/, " ").strip.sub(/\A[^[:alnum:]«"“(]+/, "")
  if mostly_upper?(t)
    t = t.downcase.sub(/[[:alpha:]]/) { |c| c.upcase }
  end
  t
end

# Postning sarlavhasi va asosiy matn qatorlarini ajratadi
def split_title(html_lines, kind)
  lines = html_lines.dup
  loop do
    f = plain(lines.first.to_s)
    break if lines.empty?
    if f.empty? || f !~ /[[:alnum:]]/ || f =~ /\A\d+\z/ || (f =~ SKIP_HEAD_RE && f.length < 90) || f =~ /\A#[[:word:]]+(\s+#[[:word:]]+)*\z/
      lines.shift
    else
      break
    end
  end
  first = plain(lines.first.to_s)
  if kind == :sher
    return [smart_title(truncate(first.sub(/[,.;:!?…–—-]+\z/, ""), 70)), lines]
  end
  heading = first.length.between?(3, 110) && (first !~ /[.!?…,;]\z/ || mostly_upper?(first))
  heading &&= !(lines.size <= 2) # yagona qatorli postda sarlavha olib tashlanmasin
  if heading
    lines.shift
    title = smart_title(first)
    if title =~ /\A(hikoyat|hikoya|ertak|rivoyat|tarjima|she’r|sher)\z/i
      nxt = lines.map { |l| plain(l) }.find { |t| !t.empty? && t =~ /[[:alnum:]]/ }
      title = "#{title}: #{truncate(nxt.sub(/[,.;:!?…]+\z/, ""), 60)}" if nxt
    end
    [title, lines]
  else
    t = smart_title(truncate(first, 84))
    t = ({ sher: "She’r", video: "Video", elon: "E’lon" }[kind] || "Yozuv") if t.empty?
    [t, lines]
  end
end

def paragraphs(lines)
  paras = lines.join("\n").split(/\n\s*\n/).map(&:strip).reject { |x| plain(x).empty? }
  paras = paras.reject { |x| plain(x) =~ /\A(👉\s*)?(davomi|boshlanishi|boshi|davomi bor)\b.{0,24}\z/i }
  paras.map do |x|
    t = plain(x)
    if t =~ SECTION_RE || (mostly_upper?(t) && t.length.between?(4, 60) && x !~ /\n/)
      "<h3>#{esc(smart_title(t))}</h3>"
    else
      "<p>#{x.gsub("\n", "<br>")}</p>"
    end
  end.join("\n")
end

def build_items(posts)
  hidden = File.exist?(HIDDEN_FILE) ? JSON.parse(File.read(HIDDEN_FILE)) : []
  kinds = File.exist?(KINDS_FILE) ? JSON.parse(File.read(KINDS_FILE)) : {}
  items = posts.map do |p|
    next if hidden.include?(p["id"]) || p["fwd"]
    html = p["html"].to_s
    text = plain(html)
    next if text.empty?
    kind = classify(p, text, html, kinds[p["id"].to_s])
    next unless kind
    lines = html.split("\n").map(&:strip)
    tags = []
    lines = lines.reject do |l|
      t = plain(l)
      next false unless t =~ /\A(#[[:word:]]+[\s,]*)+\z/
      tags.concat(t.scan(/#([[:word:]]+)/).flatten)
    end
    title, body_lines = split_title(lines, kind)
    body = paragraphs(body_lines)
    rest = plain(body_lines.join(" ")).gsub(/\s+/, " ")
    words = text.split(/\s+/).size
    {
      "id" => p["id"], "kind" => kind, "title" => title, "body" => body, "tags" => tags.uniq,
      "excerpt" => truncate(rest.empty? ? text : rest, 170), "date" => uz_date(p["date"]), "iso" => p["date"],
      "image" => download_image(p), "minutes" => [(words / 180.0).ceil, 1].max,
      "views" => views_num(p["views"]), "cyr" => cyrillic?(text), "yt" => youtube_id(html),
      "lines" => lines, "text" => text,
      "parent" => (html.lines.first.to_s =~ /(boshlanishi|boshi)\b/i ? html.lines.first.to_s[%r{t\.me/#{CHANNEL}/(\d+)}i, 1].to_i : nil),
    }
  end.compact
  merge_parts(dedupe(items))
end

# Ketma-ket qismlarga bo'lingan maqolalarni bitta sahifaga jamlaydi
def merge_parts(items)
  by_id = {}
  items.each { |a| by_id[a["id"]] = a }
  items.sort_by { |a| a["id"] }.each do |a|
    pid = a["parent"]
    next unless pid && pid > 0 && a["kind"] == :maqola
    parent = by_id[pid]
    parent = by_id[parent["merged_into"]] while parent && parent["merged_into"]
    next unless parent && parent["kind"] == :maqola && parent["id"] != a["id"]
    parent["body"] = parent["body"] + %(\n<hr class="sep">\n) + a["body"]
    parent["text"] = parent["text"] + "\n" + a["text"]
    parent["minutes"] = [(parent["text"].split(/\s+/).size / 180.0).ceil, 1].max
    parent["image"] ||= a["image"]
    a["merged_into"] = parent["id"]
  end
  items.reject { |a| a["merged_into"] }
end

# Bir xil e'lon/video takror chiqmasin (eng yangisi qoladi)
def dedupe(items)
  seen = {}
  items.reject do |a|
    key = case a["kind"]
          when :elon then "e:" + a["title"].downcase
          when :video then "v:" + a["yt"].to_s
          end
    next false unless key
    dup = seen.key?(key)
    seen[key] = true
    dup
  end
end

# «Mumtoz oila» risolasi: postlarni boblarga jamlaydi
def chapters(items)
  posts = items.select { |a| a["kind"] == :mumtoz_oila }.sort_by { |a| a["id"] }
  chs = []
  posts.each do |a|
    lines = a["lines"].dup
    lines.shift while lines.any? && plain(lines.first).empty?
    head = nil
    sub = nil
    lines.first(3).each_with_index do |l, i|
      t = plain(l)
      if t =~ CHAPTER_RE || t =~ PART_RE
        head = smart_title(t)
        lines.slice!(0, i + 1)
        lines.shift while lines.any? && plain(lines.first).empty?
        cand = plain(lines.first.to_s)
        if mostly_upper?(cand) && cand.length.between?(3, 80) && cand !~ SECTION_RE
          sub = smart_title(cand)
          lines.shift
        end
        break
      end
    end
    lines.shift while lines.any? && plain(lines.first) =~ /\A(👉\s*)?(boshlanishi|boshi|davomi)\b/i
    key = head ? head.downcase.gsub(/[ʻʼ'’‘`]/, "'").gsub(/\s+/, " ").strip : nil
    if key && (chs.empty? || chs.last["key"] != key)
      chs << { "key" => key, "head" => head, "sub" => sub, "ids" => [], "parts" => [], "iso" => a["iso"], "date" => a["date"] }
    end
    next if chs.empty?
    chs.last["sub"] ||= sub
    chs.last["ids"] << a["id"]
    chs.last["parts"] << paragraphs(lines)
    chs.last["date"] = a["date"]
  end
  chs.each_with_index do |c, i|
    c["n"] = i + 1
    c["title"] = c["sub"] ? "#{c["head"]}. #{c["sub"]}" : c["head"]
    c["body"] = c["parts"].reject(&:empty?).join(%(\n<hr class="sep">\n))
    c["words"] = plain(c["body"]).split(/\s+/).size
    c["minutes"] = [(c["words"] / 180.0).ceil, 1].max
  end
  chs
end

# ---------- Sahifalarni qurish ----------

def tpl(name)
  File.read(File.join(TPL_DIR, name), encoding: "UTF-8")
end

def fill(str, vars)
  str.gsub(/\{\{(\w+)\}\}/) { vars.fetch(Regexp.last_match(1)) { "" }.to_s }
end

def abs_url(path)
  SITE["url"].to_s.sub(%r{/\z}, "") + "/" + path
end

def page(file, root:, title:, description:, content:, image: "assets/img/og.jpg", path: "", type: "website", body_class: "")
  html = fill(tpl("layout.html"), {
    "root" => root, "title" => esc(title), "description" => esc(description),
    "canonical" => esc(abs_url(path)), "og_image" => esc(abs_url(image)), "og_type" => type,
    "content" => content, "year" => Time.now.year, "telegram" => CHANNEL, "ga" => SITE["ga"].to_s,
    "maktub" => SITE["maktub_bot"].to_s, "youtube" => SITE["youtube"].to_s, "body_class" => body_class,
  })
  out = File.join(ROOT, file)
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, html)
end

KIND_LABEL = { maqola: "Maqola", sher: "She’r", elon: "E’lon", video: "Video", taqriz: "Taqriz", mumtoz_oila: "Mumtoz oila" }.freeze
KIND_DIR = { maqola: "maqolalar", sher: "sherlar", elon: "elonlar" }.freeze

def item_path(a)
  dir = KIND_DIR[a["kind"]] or return nil
  "#{dir}/#{a["id"]}/"
end

def card(a, root)
  path = item_path(a)
  href = path ? "#{root}#{path}" : "https://t.me/#{CHANNEL}/#{a["id"]}"
  if a["kind"] == :video && a["yt"]
    href = "https://www.youtube.com/watch?v=#{a["yt"]}"
    img = %(<img src="https://i.ytimg.com/vi/#{a["yt"]}/hqdefault.jpg" alt="" loading="lazy"><span class="play"></span>)
    ext = %( target="_blank" rel="noopener")
  elsif a["image"]
    img = %(<img src="#{root}#{a["image"]}" alt="" loading="lazy">)
    ext = ""
  else
    img = %(<span class="card-mark">#{a["kind"] == :sher ? "✦" : "❝"}</span>)
    ext = ""
  end
  cls = a["kind"] == :sher ? " card-sher" : ""
  search = ([a["title"], a["excerpt"]] + a["tags"]).join(" ").downcase
  <<~HTML
    <a class="card#{cls}" href="#{href}"#{ext} data-search="#{esc(search)}" data-kind="#{a["kind"]}">
      <div class="card-img">#{img}</div>
      <div class="card-body">
        <div class="meta"><span class="kind">#{KIND_LABEL[a["kind"]]}</span>#{a["date"]}#{a["kind"] == :video ? "" : " · #{a["minutes"]} daqiqa"}</div>
        <h3>#{esc(a["title"])}</h3>
        <p>#{esc(a["excerpt"])}</p>
      </div>
    </a>
  HTML
end

def poem_card(a, root)
  first = a["lines"].map { |l| plain(l) }.reject(&:empty?).first(4)
  <<~HTML
    <a class="poem" href="#{root}sherlar/#{a["id"]}/" data-search="#{esc(([a["title"], a["excerpt"]]).join(" ").downcase)}">
      <div class="poem-lines">#{first.map { |l| esc(l) }.join("<br>")}<br>…</div>
      <div class="meta">#{a["date"]}</div>
    </a>
  HTML
end

def nav_links(list, i, root_rel, dir)
  newer = i.positive? ? list[i - 1] : nil
  older = list[i + 1]
  nav = +""
  nav << %(<a class="prev" href="#{root_rel}#{dir}/#{older["id"]}/"><span>← Oldingi</span>#{esc(older["title"])}</a>) if older
  nav << %(<a class="next" href="#{root_rel}#{dir}/#{newer["id"]}/"><span>Keyingi →</span>#{esc(newer["title"])}</a>) if newer
  nav
end

def list_page(file, path, root, title, eyebrow, lead, cards, count, extra: "", description: nil)
  page(file, root: root, path: path, title: "#{title} — #{SITE["name"]}", description: description || lead,
       content: fill(tpl("list.html"), {
         "root" => root, "cards" => cards, "count" => count, "title" => title,
         "eyebrow" => eyebrow, "lead" => lead, "extra" => extra, "telegram" => CHANNEL,
       }))
end

def taqriz_name(a)
  t = a["text"].gsub(/\s+/, " ").sub(/\A(assalomu alaykum|assalamu alaykum|ассалому алайкум|asalom alaykum|assalomu aleykum|assalaamu alaykum)[^.!]*[.!]?\s*/i, "")
  t = t.sub(/\A(mening\s+)?(ismim va familiyam|ism-?familiyam|ismi-?sharifim|ismi sharifim|ism familyam|to'liq ismim|ismim|men)\s*[—–:-]?\s*/i, "")
  truncate(t.split(/[.!?,]/).first.to_s.strip, 48)
end

def build(posts)
  items = build_items(posts)
  by_kind = Hash.new { |h, k| h[k] = [] }
  items.each { |a| by_kind[a["kind"]] << a }
  arts = by_kind[:maqola]
  poems = by_kind[:sher]
  elons = by_kind[:elon]
  videos = by_kind[:video]
  taqriz = by_kind[:taqriz]
  chs = chapters(items)

  # Ichki havolalar: t.me/<kanal>/<id> → sayt sahifasi
  links = {}
  items.each { |a| (p = item_path(a)) && (links[a["id"]] = p) }
  chs.each { |c| c["ids"].each { |id| links[id] = "mumtoz-oila/#{c["n"]}/" } }
  relink = lambda do |html, root|
    html.gsub(%r{href="https?://t\.me/#{CHANNEL}/(\d+)"[^>]*>}i) do
      id = Regexp.last_match(1).to_i
      links[id] ? %(href="#{root}#{links[id]}">) : Regexp.last_match(0)
    end
  end

  # Eski sahifalarni tozalash (yashirilganlar o'chib ketishi uchun)
  %w[maqolalar sherlar elonlar mumtoz-oila].each do |d|
    Dir.glob(File.join(ROOT, d, "*/")).each { |x| FileUtils.rm_rf(x) if File.basename(x) =~ /\A\d+\z/ }
  end

  popular = arts.sort_by { |a| -a["views"] }.first(4)

  page("index.html", root: "", title: SITE["title"], description: SITE["description"],
       content: fill(tpl("home.html"), {
         "root" => "", "telegram" => CHANNEL, "maktub" => SITE["maktub_bot"].to_s, "youtube" => SITE["youtube"].to_s,
         "latest" => arts.first(6).map { |a| card(a, "") }.join,
         "popular" => popular.map { |a| %(<li><a href="maqolalar/#{a["id"]}/">#{esc(a["title"])}</a><span>#{a["date"]}</span></li>) }.join,
         "poems" => poems.first(3).map { |a| poem_card(a, "") }.join,
         "videos" => videos.first(3).map { |a| card(a, "") }.join,
         "elons" => elons.first(3).map { |a| card(a, "") }.join,
         "chapters" => chs.first(6).map { |c| %(<li><a href="mumtoz-oila/#{c["n"]}/"><span class="n">#{c["n"]}</span>#{esc(c["title"])}</a></li>) }.join,
         "count_arts" => arts.size, "count_poems" => poems.size, "count_ch" => chs.size, "count_videos" => videos.size,
         "taqriz" => taqriz.first(3).map { |a| %(<blockquote class="taqriz"><p>#{esc(truncate(a["text"].gsub(/\s+/, " "), 260))}</p><cite>#{esc(taqriz_name(a))}</cite></blockquote>) }.join,
       }))

  list_page("maqolalar/index.html", "maqolalar/", "../", "Maqolalar", "Yozuvlar",
            "Din, axloq, oila, til, kitob va millat haqida mushohadalar. Jami #{arts.size} ta maqola.",
            arts.map { |a| card(a, "../") }.join, arts.size)

  list_page("sherlar/index.html", "sherlar/", "../", "She’rlar", "Nazm",
            "Akrom Malik qalamiga mansub she’rlar. Jami #{poems.size} ta.",
            poems.map { |a| poem_card(a, "../") }.join, poems.size, extra: "poems")

  list_page("elonlar/index.html", "elonlar/", "../", "E’lonlar", "Yangiliklar",
            "Tahsil qabuli, taqdimotlar, uchrashuvlar va boshqa e’lonlar. Jami #{elons.size} ta.",
            elons.map { |a| card(a, "../") }.join, elons.size)

  list_page("videolar/index.html", "videolar/", "../", "Videolar", "Ko‘rish",
            "Suhbatlar, ma’ruzalar, taqdimotlar va «Mumtoz suhbatlar» sonlari. Jami #{videos.size} ta video.",
            videos.map { |a| card(a, "../") }.join, videos.size)

  # Mumtoz oila
  toc = chs.map { |c| %(<li><a href="#{c["n"]}/"><span class="n">#{c["n"]}</span><span class="t">#{esc(c["title"])}</span><span class="m">#{c["minutes"]} daqiqa</span></a></li>) }.join
  page("mumtoz-oila/index.html", root: "../", path: "mumtoz-oila/", title: "«Mumtoz oila» risolasi — #{SITE["name"]}",
       description: "Akrom Malikning «Mumtoz oila» risolasi: ota, ona, farzand, oila qurish, er-xotin, qayinyurt va oila hayotining barcha jabhalari haqida #{chs.size} bob.",
       content: fill(tpl("book.html"), { "root" => "../", "toc" => toc, "count" => chs.size, "telegram" => CHANNEL,
                                         "first" => chs.first ? chs.first["n"] : 1 }))
  chs.each_with_index do |c, i|
    prev_c = i.positive? ? chs[i - 1] : nil
    next_c = chs[i + 1]
    nav = +""
    nav << %(<a class="prev" href="../#{prev_c["n"]}/"><span>← Oldingi bob</span>#{esc(prev_c["title"])}</a>) if prev_c
    nav << %(<a class="next" href="../#{next_c["n"]}/"><span>Keyingi bob →</span>#{esc(next_c["title"])}</a>) if next_c
    page("mumtoz-oila/#{c["n"]}/index.html", root: "../../", path: "mumtoz-oila/#{c["n"]}/", type: "article", body_class: "reading",
         title: "#{c["title"]} — «Mumtoz oila»", description: truncate(plain(c["body"]).gsub(/\s+/, " "), 160),
         content: fill(tpl("chapter.html"), {
           "root" => "../../", "title" => esc(c["title"]), "n" => c["n"], "count" => chs.size,
           "body" => relink.call(c["body"], "../../"), "minutes" => c["minutes"], "nav" => nav,
           "tg_link" => "https://t.me/#{CHANNEL}/#{c["ids"].first}", "telegram" => CHANNEL,
           "toc" => chs.map { |x| %(<li#{x["n"] == c["n"] ? ' class="now"' : ""}><a href="../#{x["n"]}/">#{x["n"]}. #{esc(x["title"])}</a></li>) }.join,
         }))
  end

  # Alohida sahifalar: maqola, she'r, e'lon
  { maqola: [arts, "maqolalar", "Barcha maqolalar"], sher: [poems, "sherlar", "Barcha she’rlar"], elon: [elons, "elonlar", "Barcha e’lonlar"] }.each do |kind, (list, dir, back)|
    list.each_with_index do |a, i|
      hero = a["image"] ? %(<figure class="article-img"><img src="../../#{a["image"]}" alt=""></figure>) : ""
      body = relink.call(a["body"], "../../")
      body = %(<div class="yt"><iframe src="https://www.youtube-nocookie.com/embed/#{a["yt"]}" title="YouTube" loading="lazy" allowfullscreen></iframe></div>\n) + body if a["yt"] && kind != :sher
      page("#{dir}/#{a["id"]}/index.html", root: "../../", path: "#{dir}/#{a["id"]}/", type: "article", body_class: "reading",
           title: "#{a["title"]} — #{SITE["name"]}", description: a["excerpt"], image: a["image"] || "assets/img/og.jpg",
           content: fill(tpl("article.html"), {
             "root" => "../../", "title" => esc(a["title"]), "date" => a["date"], "iso" => a["iso"], "back" => back,
             "minutes" => a["minutes"], "body" => body, "hero" => hero, "nav" => nav_links(list, i, "../../", dir),
             "kind" => KIND_LABEL[kind], "kind_class" => kind, "cyr" => a["cyr"] ? %(<div class="script-note" id="scriptNote"><span>Bu yozuv kirill alifbosida.</span><button type="button">Lotinda o‘qish</button></div>) : "",
             "tags" => a["tags"].map { |t| %(<span class="tag">##{esc(t)}</span>) }.join,
             "tg_link" => "https://t.me/#{CHANNEL}/#{a["id"]}", "telegram" => CHANNEL,
             "share" => CGI.escape(abs_url("#{dir}/#{a["id"]}/")),
           }))
    end
  end

  # Statik sahifalar
  { "haqida" => ["Akrom Malik haqida", "Tarjimai hol: tug‘ilgan joyi, ta’limi, ilmiy faoliyati, kitoblari va loyihalari."],
    "loyihalar" => ["Loyihalar", "«Mumtoz alifbo tahsili», «Mumtoz suhbatlar», «Asliyatdan o‘qiymiz», «Hayrat ul-abror» sharhi va boshqa loyihalar."],
    "kitoblar" => ["Kitoblar", "Akrom Malikning nashr etilgan kitoblari: «Halqa», «Jangchi», «Hayrat ul-abror» sharhi, «Mumtoz oila»."] }.each do |slug, (t, d)|
    page("#{slug}/index.html", root: "../", path: "#{slug}/", title: "#{t} — #{SITE["name"]}", description: d,
         content: fill(tpl("#{slug}.html"), {
           "root" => "../", "telegram" => CHANNEL, "maktub" => SITE["maktub_bot"].to_s, "youtube" => SITE["youtube"].to_s,
           "taqriz" => taqriz.first(6).map { |a| %(<blockquote class="taqriz"><p>#{esc(truncate(a["text"].gsub(/\s+/, " "), 320))}</p><cite>#{esc(taqriz_name(a))} · <a href="https://t.me/#{CHANNEL}/#{a["id"]}" target="_blank" rel="noopener">to‘liq o‘qish</a></cite></blockquote>) }.join,
           "count_ch" => chs.size,
         }))
  end

  urls = ["", "haqida/", "loyihalar/", "kitoblar/", "maqolalar/", "sherlar/", "elonlar/", "videolar/", "mumtoz-oila/"] +
         chs.map { |c| "mumtoz-oila/#{c["n"]}/" } + items.map { |a| item_path(a) }.compact
  File.write(File.join(ROOT, "sitemap.xml"),
             %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n) +
             urls.map { |u| "  <url><loc>#{abs_url(u)}</loc></url>\n" }.join + "</urlset>\n")
  puts "Qurildi: #{arts.size} maqola, #{poems.size} she'r, #{elons.size} e'lon, #{videos.size} video, #{taqriz.size} taqriz, «Mumtoz oila» #{chs.size} bob."
end

if __FILE__ == $0
posts = if ARGV.include?("--build")
          JSON.parse(File.read(POSTS_FILE, encoding: "UTF-8"))
        else
          fetch(full: ARGV.include?("--full"))
        end
build(posts)
end
