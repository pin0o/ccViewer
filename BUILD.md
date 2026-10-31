# CryptCloudViewer PoC: AltStore 向け IPA のビルド

`.github/workflows/build-ipa.yml` は `feature_thumbnail` への push または GitHub Actions の手動実行で、macOS / Xcode 26 を使って署名なし IPA を生成します。Apple の証明書・プロビジョニングプロファイルは不要です。

成功した実行の Artifacts から `CryptCloudViewerPoC-unsigned` をダウンロードしてください。ZIP 内の `CryptCloudViewerPoC-unsigned.ipa` を AltStore で署名してインストールします。

この IPA はビルド時点では未署名です。AltStore を経由せず、そのまま実機へインストールするものではありません。各クラウドサービスの OAuth 設定は README に記載された独自設定に従います。

## iOS シミュレーターのスクリーンショット

`.github/workflows/simulator-screenshots.yml` は、依存ライブラリを arm64 iOS Simulator 向けに別ビルドし、アプリ本体を起動してリスト／グリッド小・中・大の4画面を撮影します。成果物は `simulator-screenshots` です。初回は実機用とは別のネイティブライブラリを用意するため時間がかかります。

撮影には生成した横長・縦長・透過 PNG とテキスト・フォルダを Local に配置します。実際のファイル一覧・サムネイル・ツールバーを描画し、Google アカウント等の実データは使用しません。シミュレーター専用の `--snapshot-local-files` 引数で Local に遷移し、撮影用の設定を起動引数で指定します。この経路は実機ビルドには含まれません。画面撮影は実機・クラウド認証・動画再生の検証の代わりにはなりません。

Mac 上で依存ライブラリを用意した後、`bash scripts/capture-ios-simulator.sh` でも再現できます。出力先は `build/simulator-screenshots/` です。

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
- Google の `GIDClientID` と `GIDURLScheme` には、提供された PoC 用 Client ID と対応する reversed client ID を設定済みです。Google Cloud 側では iOS OAuth クライアントの Bundle ID、Drive API、OAuth 同意画面・テストユーザーを設定してください。ビルド元の Bundle ID は `io.github.pin0o.ccViewerPoC` です。AltStore が Bundle ID を変更する場合は、署名後の実際の ID に登録内容を合わせます。
- Cast の receiver ID と Google の debug API key も PoC 専用の登録情報を使用してください。現在のリポジトリでは空欄です。Cast SDK など第三者が定義する通信プロトコル名や SDK 自体の Bundle ID は、そのサービスとの互換性のために維持します。

ビルドスクリプトは IPA 作成前に、アプリと自作フレームワークの Bundle ID・アプリ表示名が PoC 用であることを検証します。

### Google Drive を追加するとき

Google OAuth の Client ID が空欄、または Client ID に対応する reversed client ID が URL スキームに登録されていないビルドでは、Google Drive の選択時に設定不足の案内を表示します。プロバイダーを作成する前に検査し、SDK の Objective-C 例外による終了を防ぎます。起動時の Google 認証復元と、バックグラウンドのトークン更新にも同じ検査を適用します。トークン更新だけでログイン画面を開くことはありません。

Google Drive を利用するには、上記の PoC 専用 OAuth クライアントを取得して設定した IPA が必要です。設定の空欄や仮の URL スキームだけでは Google にはログインできません。CI は `tests/GoogleSignInSettingsTests.swift` で、未入力・未展開変数・不整合の URL スキーム・正常設定などの回帰検証を実行します。

GitHub Actions は FFmpeg のリビジョンを固定し、iOS 17 向けにライブラリとヘッダをビルドします。同梱アーカイブは iOS 26 向けのため、iOS 17.6 との互換性を保つ目的で再利用しません。依存ライブラリはアプリのコンパイル前にキャッシュし、アプリ側の修正で再コンパイルしなくて済むようにしています。標準の SDK 相対パスで libarchive を解決し、Xcode 26 のマイナーバージョンごとの SDK ディレクトリ名に依存しません。

## ファイル一覧の表示切り替え

通常一覧・編集画面では、上部ツールバーの並べ替えアイコンのすぐ左にある「表示方法」アイコンからリスト／グリッドを選び、グリッドでは小・中・大を選択します。設定画面の「ファイル一覧」からも変更できます。表示形式とサイズは画面間で共有し、次回起動時にも復元します。

通常一覧・編集・保存先選択・プレイリストのファイル表示に対応します。グリッドの長押しメニューには、通常一覧では元ファイル表示と再生マーク、プレイリストでは前後への移動・削除を用意しています。画像の背後の四角形はサムネイル表示時に描かず、縦横比を保って表示します。

## 初回実装の検証

- 別エージェントによる静的レビューを実施し、個別キャンセル、SMB接続維持、変更後の無効化、接続の再分類、表示終了時の画像解放、TypeScript判定を修正しています。
- `tests/thumbnail_decoder_test.cpp` は独立した FFmpeg デコーダーの回帰検証用です。MP4、MKV、MPEG-TS、回転付き動画、音声のみ、破損入力、事前キャンセルを確認します。Linux の FFmpeg 7 系ライブラリで ASan / UBSan を付けて実行済みです。
- Swift の新規ファイルは構文パーサーで確認しています。iOS の型検査・リンク確認は Xcode ビルドの結果を確認してください。Linux のネイティブテストは iOS 実機検証の代わりにはなりません。
- SFTP の同期 C I/O の中断応答、各暗号化方式と接続先の組み合わせ、低速回線での挙動は実機での確認が必要です。

調査書 `RESEARCH.md` はローカル専用で、コミット対象に含めません。
