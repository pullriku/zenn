---
title: "UUIDを実装してみた！安全な乱数源から"
emoji: "🆔"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["Rust", "UUID",]
published: false
---

Rustの標準ライブラリだけで**UUID**を作りました。OSから暗号学的に安全な乱数を取得して、それを元に`B7EEF135-1372-43B9-AADF-95C4A6D19609`のようなIDを生成します。
`unsafe`を使用するため、Rustでの低レイヤープログラミング入門としていい題材になるかと思います。

本記事ではLinuxとmacOSでの動作を想定しており、ソースコードは以下にあります。

https://github.com/pullriku/rikuuid


## 仕様 & 実装方針

UUIDv4を実装します。

[UUIDv4](https://www.rfc-editor.org/info/rfc9562/#name-uuid-version-4)は、バージョン番号(4)とバリアント[^var] (`0b10`)を除けば、全てランダムなbitで構成されます。

<!-- [UUIDv7](https://www.rfc-editor.org/info/rfc9562/#name-uuid-version-7)は、前半に時刻が含まれています。後半はランダムで、バージョン番号とバリアントもあります。 -->

[^var]: バリアント: UUIDがどの形式の規格で作られているかを示す値で、仕様書で決められています。

<!-- v4はランダムなIDで、v7は時刻と乱数を組み合わせたIDですね。 -->

処理の流れとしては、まずランダムなバイト列を生成し、それにバージョン番号などを埋め込み、最後に文字列に直して完成です。
<!-- 加えて、v7の場合は時刻を取得する必要がありますね。 -->

### OSから乱数を取得する

本記事では、OSが提供する**暗号学的に安全な乱数**を使います。これは、暗号鍵生成など、予測されたくない用途で使われます。

Linuxでは、`/dev/urandom`を読むと、安全な乱数を得ることができます。しかし、本記事ではより新しい、`getrandom`システムコールを使った方法を採ろうと思います。`urandom`はファイルであるため、ファイルを開ける上限数に引っかかる可能性がありますが[^fd]、システムコールならそのような制限はありません。macOSだと`getentropy`などのインターフェースがあります。

[^fd]: 正確には、開いているファイルディスクリプタの上限です。

## 実装

バイト列を作ってから文字列にします。[^err]

```rust
pub fn uuid_v4() -> Result<String> {
    let bytes = uuid_v4_from_random(
        random_bytes_16()?
    );

    Ok(bytes_to_uuid_string(bytes))
}
```
```rust
pub type Result<T> = std::result::Result<T, UuidError>;
```

[^err]: エラー`MyUuidError`については割愛します。詳細はGitHubリポジトリをご覧ください。

### 乱数生成(Linux)

まずは乱数生成ですね。Linux版から見てみましょう。

`getrandom`システムコールを使うので、`man 2 getrandom`で使い方を確認します。

引数と戻り値は`SYNOPSIS`(書式)セクションに書いてあります。

```c
ssize_t getrandom(
    void *buf,
    size_t buflen,
    unsigned int flags
);
```

ランダムバイト列を入れるバッファ`buf`とその長さ`buflen`が必要なようですね。`flags`は今回は使いません。

戻り値については`RETURN VALUE`セクションに書いてあります。
成功すると、生成したバイト長を返し、失敗すると`-1`を返します。

ただし今回は、生成する乱数の長さは最大でも16バイトです。`getrandom`では、256バイト以下の生成の際、**要求したバイト数ぶんを必ず返す仕様になっています**。そのため、合計で16バイト埋まるまでループを書く必要はなく、単に戻り値をチェックして、予期しないものならエラーにすればいいだけです。

`getrandom`をRust側で宣言してから作っていきます。

```rust
#[cfg(target_os = "linux")]
unsafe extern "C" {
    fn getrandom(
        buf: *mut c_void,
        buflen: usize, 
        flags: c_uint
    ) -> isize;
}
```

```rust
#[cfg(target_os = "linux")]
pub(crate) fn random_bytes_16() 
-> io::Result<[u8; 16]> {
    let mut buf = MaybeUninit::<[u8; 16]>::uninit();

    let ret = unsafe {
        getrandom(buf.as_mut_ptr().cast(), 16, 0)
    };

    if ret == 16 as isize {
        unsafe { Ok(buf.assume_init()) }
    } else {
        Err(std::io::Error::last_os_error())
    }
}
```

未初期化の配列を作り、ポインタと長さ`16`、flags`0`を渡しています。`.cast()`で、`*mut [u8; 16]`型を`*mut c_void`型にキャストしないとエラーになります。

戻り値が`16`なら、用意した未初期化配列に値が書き込まれたことが保証できるため、`assume_init`(初期化を仮定)します。
そうでないならエラーにします。

### 乱数生成(macOS)

macOS版もほぼ同じです。呼び出すのが`getentropy`関数なのと、`flags`がないのがLinuxと違いますね。

```rust
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn getentropy(
        buf: *mut c_void,
        buflen: usize
    ) -> c_int;
}
```
```rust
#[cfg(target_os = "macos")]
pub(crate) fn random_bytes_16() -> io::Result<[u8; 16]> {
    let mut buf = MaybeUninit::<[u8; 16]>::uninit();

    let ret = unsafe {
        getentropy(buf.as_mut_ptr().cast(), 16)
    };

    if ret == 0 {
        unsafe { Ok(buf.assume_init()) }
    } else {
        Err(std::io::Error::last_os_error())
    }
}
```

### 定数の埋め込み

バージョン番号(4)とバリアント(`0b10`)を、適切な位置に埋め込みます。

改めて、[仕様書](https://www.rfc-editor.org/info/rfc9562/#name-uuid-version-4)から定義を引用します。

```txt
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           random_a                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          random_a             |  ver  |       random_b        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|var|                       random_c                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           random_c                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

1行に4バイト分が書かれていますね。0から数えると、バージョン`ver`は、6バイト目、バリアント`var`は8バイト目であることがわかります[^octet]。これをもとに、ビット演算を用いて定数を埋め込みます。

[^octet]: ネットワークやバイナリ形式の仕様では、1バイトのことを「1オクテット」と呼ぶことがあります。そのため、ここでは「6バイト目」「8バイト目」は、仕様書風に言えば、「第6オクテット」「第8オクテット」にあたります。

```rust
pub const N_UUID_BYTES: usize = 16;
```
```rust
fn uuid_v4_from_random(
    mut bytes: [u8; N_UUID_BYTES]
) -> [u8; N_UUID_BYTES] {
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    bytes
}
```

バージョン番号の埋め込みを図で表すと次のようになります。

![bytes[6] に対して 0x0f との AND を行い上位 4 ビットを 0 にする。その後 0x40 との OR を行い、上位 4 ビットを UUID v4 のバージョン番号 0100 に設定する処理を示した図。](/images/articles/rikuuid-rust/bit.png)
*`bytes[6]` に対してまず`0x0f`とのANDを行い、上位4ビットをクリアする。その後`0x40`とのORを行うことで、UUID v4のバージョン番号を表すビット列`0b0100`を上位4ビットに設定する。*

バリアントの場合も、値が変わるだけで同様の処理です。

![bytes[8]に対して、0x3fとのANDを行い、上位2ビットをクリアする。その後、0x80とのORを行うことで、UUID v4のバリアントを表すビット列`0b10`を上位2ビットに設定する。](/images/articles/rikuuid-rust/var.png)
*`bytes[8]`に対して、`0x3f`とのANDを行い、上位2ビットをクリアする。その後、`0x80`とのORを行うことで、UUID v4のバリアントを表すビット列`0b10`を上位2ビットに設定する。*

これで、以下の`bytes`が完成しました。

```rust
pub fn uuid_v4() -> Result<String> {
    let bytes = uuid_v4_from_random(
        random_bytes_16()?
    );

    Ok(bytes_to_uuid_string(bytes))
}
```

ここからは、`bytes`をUUIDにする工程になります。

### UUID文字列への変換

UUID文字列は、16進数表記とハイフン(`-`)で構成されます。
各バイトを16進数表記にしつつ、適切な位置にハイフンを挿入します。そのために、ループ変数`i`と、`buf`への書き込み位置`current`を用いています。

```rust
pub(crate) fn bytes_to_uuid_string(
    bytes: [u8; N_UUID_BYTES]
) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";

    let mut buf = [0u8; 36];
    let mut current: usize = 0;

    for (i, byte) in bytes.iter().copied().enumerate() {
        if matches!(i, 4 | 6 | 8 | 10) {
            buf[current] = b'-';
            current += 1;
        }

        buf[current] = HEX[(byte >> 4) as usize];
        buf[current + 1] = HEX[(byte & 0x0f) as usize];
        current += 2
    }

    String::from_utf8(buf.to_vec())
        .expect("UUID string contains only ASCII hex digits and hyphens")
}
```

1バイトを16進数表記にすると2文字になるため、その各文字をビット演算で計算しています。
最後の`String::from_utf8`は、実装が合っていればパニックすることはありません。

## 完成

作成した`uuid_v4`関数を実行すると、UUID文字列が生成されます。

```rust
fn main() {
    let uuid = uuid_v4().unwrap();
    println!("{}", uuid);
}
```
```text
$ cargo run --release
    Finished `release` profile [optimized] target(s) in 0.05s
     Running `target/release/rikuuid`
e6b3e6b6-2686-4de1-91bc-37773d1f8ef3
```

試しに複数回実行してみましょう。

```sh
$ for _ in {0..100}; do ./target/release/rikuuid; done
d5de9e3f-5ac8-4741-b47b-6976157cd214
f9ed8131-bda3-4ebb-a112-c144e7b03455
fa8e02ef-a49f-44df-bde1-d5c7d38b8e43
3b2852b0-de67-40b5-9360-d43fff670da2
7c45e326-7482-432e-87cd-070130001311
c6663b3f-558b-4090-820f-8f02ec2740e4
6097ca0a-d811-4342-a9ef-f5d2de8263fc
819d8849-42a1-4f9f-8a8e-64edb9bb4496
f86f37e5-6f7c-4796-9435-9d492c9d616f
# ...
```

正しく実装できていれば、毎回違うUUID文字列が出力されます。また、3つ目のブロックの先頭が必ず`4`になり、4つ目のブロックの先頭が`8`・`9`・`a`・`b`のどれかになります。

コマンドを使って、このことを確認してみましょう。

```sh
for _ in {1..1000}; do ./target/release/rikuuid; done | 
grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' |
sort -u |
wc -l
```

結果は`1000`となり、1000個すべてが正規表現にマッチし、かつ全て異なるUUID文字列であることが確認できました。

## まとめ

標準ライブラリだけでもUUIDを作れました(乱数の質は検証していませんが)。

本番用途では、[`uuid`](https://crates.io/crates/uuid)のようなクレートを使いましょう。
