# Akrom Malik — rasmiy sayt

Statik sayt (GitHub Pages). Kontent **@AkromMalikUz** Telegram kanalidan avtomatik olinadi:
GitHub Actions har 2 soatda `tools/sync.rb` ni ishga tushiradi, yangi postlarni oladi, sahifalarni quradi va saqlaydi.

Postlar avtomatik tasniflanadi:

- **Maqola** — 500 belgidan uzun nasriy postlar → `maqolalar/<id>/`
- **She’r** — qisqa qatorli postlar → `sherlar/<id>/`
- **E’lon** — ariza/qabul/taqdimot haqidagi postlar → `elonlar/<id>/`
- **Video** — YouTube havolali qisqa postlar → `videolar/`
- **«Mumtoz oila»** — `#mumtoz_oila` belgili postlar boblarga jamlanadi → `mumtoz-oila/<n>/`
- **Taqriz** — tahsil o‘quvchilarining fikrlari → bosh sahifa va `loyihalar/`

Forward qilingan postlar saytga chiqmaydi.

Boshqarish:

- Postni yashirish: raqamini `data/hidden.json` ga qo‘shing (masalan `[1431, 1436]`).
- Tasnifni qo‘lda belgilash: `data/kinds.json` — `{"1325": "maqola", "636": "elon"}`.
- Bosh sahifa, tarjimai hol, loyihalar, kitoblar matni: `tools/templates/*.html`.
- Dizayn: `assets/style.css`. Sayt sozlamalari (manzil, kanal): `data/site.json`.

Qo‘lda ishga tushirish:

    ruby tools/sync.rb          # yangi postlar
    ruby tools/sync.rb --full   # butun tarix
    ruby tools/sync.rb --build  # faqat qayta qurish
