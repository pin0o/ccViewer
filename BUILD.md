# CryptCloudViewer PoC: AltStore 向け IPA のビルド

`.github/workflows/build-ipa.yml` は `feature_thumbnail` への push または GitHub Actions の手動実行で、macOS / Xcode 26 を使って署名なし IPA を生成します。Apple の証明書・プロビジョニングプロファイルは不要です。

成功した実行の Artifacts から `CryptCloudViewerPoC-unsigned` をダウンロードしてください。ZIP 内の `CryptCloudViewerPoC-unsigned.ipa` を AltStore で署名してインストールします。

この IPA はビルド時点では未署名です。AltStore を経由せず、そのまま実機へインストールするものではありません。各クラウドサービスの OAuth 設定は README に記載された独自設定に従います。

## ローカルの Mac で実行

README の手順に従い、サブモジュール・OpenSSL・libssh・FFmpeg・Google Cast SDK を準備した後に実行します。

```bash
bash scripts/build-ipa.sh
```

出力先は `build/ipa/CryptCloudViewerPoC-unsigned.ipa`、ログは `build/ipa/xcodebuild.log` です。`IPA_BUILD_DIR` で絶対パスの出力先を指定できます。

## 元アプリとの識別・保存先の分離

| 対象 | PoC の設定 |
| --- | --- |
| ホーム画面の表示名 | `CryptCloudViewer PoC` |
| アプリ Bundle ID | `io.github.pin0o.ccViewerPoC` |
| 内蔵フレームワーク Bundle ID | `io.github.pin0o.RemoteCloudPoC` / `io.github.pin0o.ffplayerPoC` / `io.github.pin0o.ffconverterPoC` |
| iCloud / CloudKit / CloudDocuments | `iCloud.io.github.pin0o.ccViewerPoC` |
| iCloud Key-Value Store | `$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` |
| Keychain service | `io.github.pin0o.ccViewerPoC`（全件削除もこの service 内に限定） |
| 課金商品 ID | `io.github.pin0o.ccViewerPoC.coffee` / `.orange` / `.dinner` |

UserDefaults、Core Data、キャッシュ、Files に公開する Documents は新しい Bundle ID のサンドボックスに保存されます。バックグラウンド処理 ID は Bundle ID から生成します。元アプリや旧 Bundle ID のビルドから、設定・認証情報・再生履歴を自動で移行しません。旧アプリを残したまま、新しいアプリで接続設定を行ってください。iCloud 同期の初期値は OFF とし、PoC 用コンテナと署名の設定が完了してから ON にします。

元の開発チーム ID と App Store Connect のアプリ・商品内部 ID は削除しました。StoreKit 設定は PoC 専用のローカルテスト用で、元アプリの課金商品にはアクセスしません。実際の課金商品は登録していません。プロジェクト / Swift モジュール / 実行ファイルの内部名はビルド参照用に維持し、インストールと保存先を決める識別子を変更しています。元アプリと依存ライブラリの著作権・ライセンス表記は維持します。

### 自分のアカウントで用意する外部設定

- Xcode で署名する場合は、自分の Development Team を設定してください。iCloud を使う場合は PoC の App ID と上記コンテナを自分の Apple Developer アカウントで登録します。AltStore の署名方式で対応できない entitlement や iCloud 機能は利用できません。
- Dropbox の redirect URI は `io.github.pin0o.ccviewer-poc.dropbox://dropbox_callback`、OneDrive は `io.github.pin0o.ccviewer-poc.onedrive://auth`、pCloud は `io.github.pin0o.ccviewer-poc.pcloud://oauth2redirect` です。各プロバイダーで PoC 用クライアントを作成し、`RemoteCloud/RemoteCloud/Secret.swift` の空欄を設定してください。
- Google は `io.github.pin0o.ccViewerPoC` 用の iOS OAuth クライアントを作成し、`Secret.xcconfig` の `GIDClientID` と、それに対応する reversed client ID を `GIDURLScheme` に設定してください。初期値 `io.github.pin0o.ccviewer-poc.google` は元アプリと重複しない仮値で、Google 認証用の登録済みスキームではありません。
- Cast の receiver ID と Google の debug API key も PoC 専用の登録情報を使用してください。現在のリポジトリでは空欄です。Cast SDK など第三者が定義する通信プロトコル名や SDK 自体の Bundle ID は、そのサービスとの互換性のために維持します。

ビルドスクリプトは IPA 作成前に、アプリと自作フレームワークの Bundle ID・アプリ表示名が PoC 用であることを検証します。

GitHub Actions は FFmpeg のリビジョンを固定し、iOS 17 向けにライブラリとヘッダをビルドします。同梱アーカイブは iOS 26 向けのため、iOS 17.6 との互換性を保つ目的で再利用しません。依存ライブラリはアプリのコンパイル前にキャッシュし、アプリ側の修正で再コンパイルしなくて済むようにしています。標準の SDK 相対パスで libarchive を解決し、Xcode 26 のマイナーバージョンごとの SDK ディレクトリ名に依存しません。

## 初回実装の検証

- 別エージェントによる静的レビューを実施し、個別キャンセル、SMB接続維持、変更後の無効化、接続の再分類、表示終了時の画像解放、TypeScript判定を修正しています。
- `tests/thumbnail_decoder_test.cpp` は独立した FFmpeg デコーダーの回帰検証用です。MP4、MKV、MPEG-TS、回転付き動画、音声のみ、破損入力、事前キャンセルを確認します。Linux の FFmpeg 7 系ライブラリで ASan / UBSan を付けて実行済みです。
- Swift の新規ファイルは構文パーサーで確認しています。iOS の型検査・リンク確認は Xcode ビルドの結果を確認してください。Linux のネイティブテストは iOS 実機検証の代わりにはなりません。
- SFTP の同期 C I/O の中断応答、各暗号化方式と接続先の組み合わせ、低速回線での挙動は実機での確認が必要です。

調査書 `RESEARCH.md` はローカル専用で、コミット対象に含めません。
