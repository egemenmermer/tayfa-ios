# Security policy

**[Türkçe ↓](#güvenlik-politikası)**

Report suspected vulnerabilities privately through [GitHub's private vulnerability reporting](https://github.com/egemenmermer/tayfa-ios/security/advisories/new). If the problem is on the server side, report it in the [Tayfa repository](https://github.com/egemenmermer/tayfa/security/advisories/new) instead.

Do not post credentials, users' private content or exploit details in public issues. In the private report, include the affected version or commit, the impact, a small and safe way to reproduce it, and how to reach you. Test only against servers and accounts you are authorized to use.

The app keeps the session token in device-only Keychain and never stores passwords. It rejects redirects and endpoints outside the configured HTTPS origin, keeps media grants in memory only, and never receives LiveKit API secrets or cinema provider credentials. There is no end-to-end encryption against the server operator: whoever runs the server is responsible for TLS, access control, retention and their community's privacy disclosures.

---

## Güvenlik politikası

Şüpheli güvenlik açıklarını [GitHub'ın özel güvenlik bildirimi](https://github.com/egemenmermer/tayfa-ios/security/advisories/new) üzerinden bildir. Sorun sunucu tarafındaysa [Tayfa deposunda](https://github.com/egemenmermer/tayfa/security/advisories/new) bildir.

Kimlik bilgilerini, kullanıcıların özel içeriklerini veya açığın kötüye kullanım ayrıntılarını herkese açık issue'larda paylaşma. Özel bildirimde etkilenen sürümü/commiti, etkiyi, güvenli ve küçük bir yeniden üretim örneğini ve iletişim yolunu belirt. Yalnızca kullanmaya yetkili olduğun sunucu ve hesaplarda test yap.

Uygulama oturum token'ını yalnızca cihazdaki Keychain'de tutar, şifreyi hiç saklamaz. Yönlendirmeleri ve yapılandırılmış HTTPS adresi dışındaki uç noktaları reddeder, medya yetkilerini yalnızca bellekte tutar; LiveKit API anahtarları ve sinema sağlayıcı bilgileri telefona hiç gelmez. Sunucu operatörüne karşı uçtan uca şifreleme yoktur: sunucuyu çalıştıran kişi TLS, erişim kontrolü, saklama süreleri ve topluluğunun gizlilik açıklamalarından sorumludur.
