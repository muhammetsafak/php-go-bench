# Nerede kaldık — 2026-09-17, 14:45 UTC

Bu dosya bir çalışma notudur, depo belgesi değil. İş bitince silinebilir.

## Şu an ne koşuyor

```
bash -c 'STAMP=2026-09-17 ./bench/capacity.sh --grid && STAMP=2026-09-17 ./bench/capacity.sh --soak'
```

`caffeinate -dimsu` altında, PPID=1 (init'e devredilmiş) — terminal, oturum ya
da ağ kapansa da devam eder. Log: `/tmp/capacity-run3.log`.

- Izgara fazı ~14:55 UTC'de biter (27 hücrenin 24'ü 14:37'de bitmişti)
- Soak fazı ~16:05 UTC'de biter
- Çıktı: `results/capacity-2026-09-17/` (steps.jsonl, raw/, tuning.jsonl)

Koşu bittikten sonra:

```sh
node bench/capacity-report.mjs 2026-09-17     # summary.json + summary.csv + tablolar
git add -A && git commit                       # sonuçlar henüz commit'li değil
```

## Geçerli olan ölçümler

| Faz | Durum | Not |
|---|---|---|
| `floor` | ✅ geçerli | Uygulama kodu koşmayan nginx: 1/2/4 çekirdekte 60.000/sn hedefi tutuyor, tam gazda 173k–670k/sn. Yük üreteci darboğaz değil. |
| `dbceiling` | ✅ geçerli | PostgreSQL'in kendi INSERT tavanı 4 çekirdekte **68.212 tps** (64 istemci, 3,45 çekirdek). Karışımın hiçbir yerinde darboğaz değil. **Dikkat:** pgbench `-j 4` ile 22k, `-j 8` ile 61k rapor eder; düşük olan pgbench'in kendi sınırıdır. |
| `tune` | ✅ geçerli | Havuz boyutu süpürmesi. Her adayda en yüksek throughput'u veren boyut aynı zamanda en iyi p99'u veriyor. Seçilenler: go 16/64/64, fpm 8/16/32, frankenphp 8/8/8 (1/2/4 çekirdek). |
| `ladder` deneme 1 | ❌ elendi | `EXCLUDED.md` |
| `ladder` deneme 2 | ❌ elendi | `EXCLUDED.md` |
| `grid` | ⚠️ **açık sorun** | aşağıya bak |

Ayar fazının kapalı-çevrim tam gaz sayıları (kararlı, tekrarlar arası birkaç yüzde):

| | 1 çekirdek | 2 çekirdek | 4 çekirdek |
|---|---|---|---|
| Go | 17.042 | 29.721 | 55.715 |
| PHP-FPM | 6.188 | 11.260 | 20.379 |
| FrankenPHP | 6.071 | 14.580 | 25.556 |

## Açık sorun: ızgaranın 2 ve 4 çekirdekli hücreleri

Ara raporda dokuz hücrenin beşi "hiçbir ızgara hızını taşımadı" (kapasite 0)
çıkıyor. Sebep servis seviyesinin p99 ≤ 10 ms şartı: bu hücrelerde **sunucunun
kendi p99'u (time to first byte) hızdan bağımsız olarak 16–44 ms'de takılıyor.**

Örnek — go, 2 çekirdek, üç tekrarın medyanı:

| hedef | geçen | client p99 | **server p99** | cpu/istek |
|---|---|---|---|---|
| 7.500 | 1/3 | 53,8 ms | **44,3 ms** | 122 µs |
| 16.250 | 0/3 | 2.832 ms | **40,0 ms** | 83 µs |
| 25.250 | 0/3 | 901 ms | **21,8 ms** | 67 µs |
| 34.250 | 0/3 | 5.298 ms | **16,2 ms** | 65 µs |

Server p99'un hız arttıkça DÜŞMESİ, kuyruk değil **epizodik bir duraklama**
demek. Aynı aday 1 çekirdekte 14.500/sn'yi server p99 4,86 ms ile taşıyor.

**En güçlü iz: havuz boyutu.** Server p99 tabanı havuz boyutuyla birlikte
büyüyor gibi görünüyor:

| aday | havuz | server p99 tabanı |
|---|---|---|
| fpm 1c | 8 | 2,3 ms |
| fpm 2c | 16 | 3,3 ms |
| go 1c | 16 | 4,9 ms |
| fpm 4c | 32 | 8,3 ms |
| go 2c / 4c | 64 | 20–44 ms |

`frankenphp` her bütçede 8 worker kullandığı hâlde 2c/4c'de kötü — yani tek
açıklama bu değil. Sınanacak ilk hipotez: **pgx havuzunun sağlık kontrolü /
boşta bağlantı döngüsü** (`MinConns=MaxConns=64`) yeni bağlantı açtığında
istek başına birkaç on milisaniye ekliyor olabilir. Bu hızdan bağımsızdır ve
havuz büyüdükçe sıklaşır — gözlemle örtüşüyor. Ama `frankenphp`'nin PDO'su için
aynı mekanizma yok, o ayrı bakılmalı.

Diğer aday açıklamalar (elenmedi): `reset_events`'in CHECKPOINT geri yazımının
5 saniyelik bekleme sonrası hâlâ sürmesi; PostgreSQL'in kendi checkpoint'i;
macOS'un VM vCPU'larını verimlilik çekirdeğine taşıması.

**Karar bekliyor:** p99 ≤ 10 ms servis seviyesi bu tezgâhta 2+ çekirdekli
hücreler için fazla dar olabilir. Seçenekler: (a) sebebi bulup düzeltmek,
(b) servis seviyesini server p99 üzerinden tanımlamak ve eşiği ölçülen tabana
göre gerekçelendirmek, (c) kaydı "istek başına CPU" ekseninde yazıp kapasiteyi
ikincil ve aralıklı vermek. CPU/istek sayıları her hücrede kararlı ve sağlam.

## İçerik tarafı — muhammetsafak.com.tr

- Eski kayıt **tamamen silindi** (commit `c05440f`): iki dil MDX, OG kartları,
  dist kalıntıları, llms.txt girdileri. Yönlendirme YOK (kullanıcı kararı).
- Yeni kayıt **henüz yazılmadı.** Yazım zinciri (CLAUDE.md zorunlu kılıyor):
  `postbriefbuilder` → `posthookcraft` → gerekirse `postnarrativearc` → gövde →
  `postguardian` → kapak/OG kartı (`scripts/generate-og-cards.mjs`,
  `scripts/check-og-cards.mjs`) → `npm run build` (check-seo.mjs 42 bekçi).
- Şema ve yayın sözleşmesi: `.ssot/RESEARCH.md`. Kayıt `measurement` türünde,
  program `servis-yuk`, TR + EN ikizi aynı `translationKey` ile, EN slug
  İngilizce.
