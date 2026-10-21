# Contributing

**[Türkçe ↓](#katkıda-bulunma)**

This is the iPhone app for [Tayfa](https://github.com/egemenmermer/tayfa). It talks to an existing Tayfa server and adds no backend of its own, so changes to accounts, rooms, cinema or the server protocol belong in the desktop and server repository.

1. Before changing anything, describe the problem you saw or the user flow you are aiming for.
2. Keep the scope narrow; keep behaviour changes apart from formatting or refactoring.
3. Put protocol, parsing and state logic in `Packages/RoomsCore` with tests; keep SwiftUI views thin.
4. Run `swift test --package-path Packages/RoomsCore` and build for a physical iPhone. Say what you tested on a real device and what you could not test (Bluetooth, cellular/TURN, background, a second desktop client).
5. In the PR, describe the problem, the resulting behaviour, how you verified it, and any configuration impact.

Use your own Tayfa server or a test community, and your own Apple team and bundle IDs. Never commit `Configuration/Local.xcconfig`, server addresses, provisioning profiles, certificates, tokens or other people's messages and media. Do not access or disrupt someone else's community for development. Interface copy is Turkish for now; code, comments and documentation are English.

For security problems, follow [SECURITY.md](SECURITY.md).

---

## Katkıda bulunma

Bu depo [Tayfa](https://github.com/egemenmermer/tayfa)'nın iPhone uygulamasıdır. Mevcut bir Tayfa sunucusuyla konuşur ve kendi arka ucu yoktur; hesap, oda, sinema veya sunucu protokolü değişiklikleri masaüstü ve sunucu deposuna aittir.

1. Değişiklikten önce gözlenen sorunu veya hedeflenen kullanıcı akışını açıkla.
2. Kapsamı sınırlı tut; davranış değişikliğini biçimlendirme veya yeniden düzenlemeden ayır.
3. Protokol, ayrıştırma ve durum mantığını testleriyle birlikte `Packages/RoomsCore` içine koy; SwiftUI görünümlerini ince tut.
4. `swift test --package-path Packages/RoomsCore` çalıştır ve fiziksel iPhone için derle. Gerçek cihazda neyi denediğini, neyi deneyemediğini (Bluetooth, hücresel/TURN, arka plan, ikinci bir masaüstü istemcisi) yaz.
5. PR'da sorunu, oluşan davranışı, doğrulamayı ve yapılandırma etkisini anlat.

Kendi Tayfa sunucunu veya bir test topluluğunu, kendi Apple takımını ve bundle ID'lerini kullan. `Configuration/Local.xcconfig`, sunucu adresi, provisioning profili, sertifika, token veya başkalarının mesaj ve medyasını asla commit etme. Geliştirme amacıyla başkasının topluluğuna erişme veya işleyişini bozma. Arayüz metinleri şimdilik Türkçe; kod, yorumlar ve belgeler İngilizce.

Güvenlik sorunlarında [SECURITY.md](SECURITY.md) yolunu izle.
