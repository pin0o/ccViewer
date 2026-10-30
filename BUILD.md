# AltStore 向け IPA のビルド

`.github/workflows/build-ipa.yml` は `feature_thumbnail` への push または GitHub Actions の手動実行で、macOS / Xcode 26 を使って署名なし IPA を生成します。Apple の証明書・プロビジョニングプロファイルは不要です。

成功した実行の Artifacts から `CryptCloudViewer-unsigned` をダウンロードしてください。ZIP 内の `CryptCloudViewer-unsigned.ipa` を AltStore で署名してインストールします。

この IPA はビルド時点では未署名です。AltStore を経由せず、そのまま実機へインストールするものではありません。各クラウドサービスの OAuth 設定は README に記載された独自設定に従います。

## ローカルの Mac で実行

README の手順に従い、サブモジュール・OpenSSL・libssh・FFmpeg・Google Cast SDK を準備した後に実行します。

```bash
bash scripts/build-ipa.sh
```

出力先は `build/ipa/CryptCloudViewer-unsigned.ipa`、ログは `build/ipa/xcodebuild.log` です。`IPA_BUILD_DIR` で絶対パスの出力先を指定できます。

GitHub Actions は元リポジトリに含まれる arm64 iOS 用 FFmpeg バイナリを再利用し、同じリビジョンの公開ヘッダを生成します。依存ライブラリはアプリのコンパイル前にキャッシュし、アプリ側の修正で再コンパイルしなくて済むようにしています。標準の SDK 相対パスで libarchive を解決し、Xcode 26 のマイナーバージョンごとの SDK ディレクトリ名に依存しません。

## 初回実装の検証

- 別エージェントによる静的レビューを実施し、個別キャンセル、SMB接続維持、変更後の無効化、接続の再分類、表示終了時の画像解放、TypeScript判定を修正しています。
- `tests/thumbnail_decoder_test.cpp` は独立した FFmpeg デコーダーの回帰検証用です。MP4、MKV、MPEG-TS、回転付き動画、音声のみ、破損入力、事前キャンセルを確認します。Linux の FFmpeg 7 系ライブラリで ASan / UBSan を付けて実行済みです。
- Swift の新規ファイルは構文パーサーで確認しています。iOS の型検査・リンク確認は Xcode ビルドの結果を確認してください。Linux のネイティブテストは iOS 実機検証の代わりにはなりません。
- SFTP の同期 C I/O の中断応答、各暗号化方式と接続先の組み合わせ、低速回線での挙動は実機での確認が必要です。

調査書 `RESEARCH.md` はローカル専用で、コミット対象に含めません。
