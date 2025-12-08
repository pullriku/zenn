---
title: "Pythonの print はどう動く？ ― バイトコードからlibcの呼び出しまで"
emoji: "⛏️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["Python", "CPython"]
published: true
---

## はじめに

Pythonを学ぶとき、最初に書くコードといえば、やはりこれでしょうね！

```python
print("Hello, world!")
```

実行すれば一瞬で完了しますが、裏側ではPython仮想マシン、C言語の標準ライブラリ（libc）、そしてOSカーネルがバケツリレーのようにデータを渡しています。

Pythonの標準機能の多くは、裏側でC言語の関数を呼び出すことで実現されています。
今回は「Python編」として、Pythonのソースコードが実行され、最終的に「C言語の世界（libc）」 に足を踏み入れる瞬間までを追ってみましょう。

:::details 検証環境

本記事では、以下の環境で調査を行いました。

- アーキテクチャ: x86_64
- OS: Ubuntu 22.04.5 LTS

Pythonの実装はCPythonを使用しました。
CPythonのソースコードはGitHubの公式リポジトリの「v3.14.0」タグをチェックアウトして使用しました。

https://github.com/python/cpython

```sh
git clone --depth 1 https://github.com/python/cpython.git
cd cpython
git checkout v3.14.0
```

また、Pythonプログラムを実行する際は、[`uv`](https://docs.astral.sh/uv/)を用いてバージョンを固定しています。

```sh
uv init --app dis-hello
cd dis-hello
uv python install 3.14.0
uv python pin 3.14.0
# main.pyを編集
uv run main.py
```

:::

## Pythonインタプリタという名のプログラム

深掘りを始める前に、私たちが普段`python`や`python3`コマンドとして呼び出しているものの正体を整理しておきましょう。

よく「Pythonプログラムを実行する」と言いますが、厳密にはPythonインタプリタというプログラムが、Pythonソースコードをデータとして読み込んで処理している状態です。

### インタプリタもまた、コンパイルされたプログラムである

Pythonインタプリタ自体（/usr/bin/python3などにある実行ファイル）は、誰かが魔法で作ったわけではありません。

1. インタプリタ自体のビルド
   CPythonの開発者が書いた大量のC言語コードを、[gcc](https://gcc.gnu.org)などのコンパイラでコンパイルして作られた、実行可能バイナリです。私たちが普段インストールしているのはこの完成品です。
1. スクリプトの実行
    私たちが`python3 hello.py`を実行するとき、OSから見れば、単に「`python`という名前のC製アプリケーションが起動し、テキストファイルを読み込んだ」に過ぎません。

<!-- 図を入れる -->

### インタプリタの内部動作

インタプリタはソースコードを1行ずつ実行するわけではなく、以下のような段階を踏んで処理を行います。

1. コンパイル
   Pythonソースコードをバイトコードに変換します。[^compile]バイトコードは「Pythonのためのミニ命令セット」で、あり、Python仮想マシンが解釈して実行します。実際のCPU命令とは異なり、Python独自の命令セットです。
1. 実行
    バイトコードをPython仮想マシンが解釈し、実行します。

つまり、`print`関数が実行される前に、ソースコードは一度「仮想マシンへの命令書」に変換されているのです。

[^compile]: 字句解析や構文解析などを経てバイトコードに変換されます。

## バイトコード

前節で、Pythonは実行前にバイトコードを作ると説明しました。
では、実際に`print("Hello, world!")`がどのようなバイトコードに変換されるのかを、標準ライブラリの`dis` (disassembler) モジュールを使って確認してみましょう。

```python
import dis
dis.dis('print("Hello, world!")')
```

実行結果は以下のようになりました。

```txt
  0           RESUME                   0

  1           LOAD_NAME                0 (print)
              PUSH_NULL
              LOAD_CONST               0 ('Hello, world!')
              CALL                     1
              RETURN_VALUE
```

この出力が、Python 仮想マシンが実際に処理している命令の列です。一つずつ読み解いていきましょう。

- **`LOAD_NAME`**: `print`という名前のオブジェクトをロードします。ここでは組み込み関数の`print`がロードされます。[^assign]
- `PUSH_NULL`: 関数呼び出しの調整用です。詳細は省きます。
- **`LOAD_CONST`**: `"Hello, world!"`という文字列定数をロードします。
- **`CALL`**: 先ほどロードした`print`関数を、引数（`"Hello, world!"`）とともに呼び出します。

[^assign]: ただし、`print = "プリント"`のように再定義されている場合は、その新しいオブジェクトがロードされます。

### CALL 命令の先

`CALL`が実行された瞬間、制御はPython仮想マシンから離れ、C言語で実装された`print`関数の実体へと移ります。[^bound]ここが、PythonとC言語の世界の境界線です。

[^bound]: Pythonで定義された関数では、インタプリタが処理を継続します。

## C言語の世界へ

`print`関数の実装のみを紹介してもいいのですが、せっかくなのでCPythonインタプリタのソースコードを辿りながら、どのようにしてC言語の関数が呼び出されるのかを見ていきましょう。

大まかな流れとしては、先に`print`関数などの組み込み関数が定義され、そのあとにユーザが書いたPythonコードの実行が始まります。

### Pythonのはじまり

C言語では、基本的にプログラムの実行は`main`関数から始まります。
PythonもただのCプログラムなので、この関数から実行が始まります。

```c:Programs/main.c
#include "Python.h"

int
main(int argc, char **argv)
{
    return Py_BytesMain(argc, argv);
}
```

その`Py_BytesMain`の実装も確認できます。

```c:Modules/main.c
int
Py_BytesMain(int argc, char **argv)
{
    _PyArgv args = {
        .argc = argc,
        .use_bytes_argv = 1,
        .bytes_argv = argv,
        .wchar_argv = NULL};
    return pymain_main(&args);
}
```

このようにして、ここからの関数呼び出しを辿っていきます。
さすがに全てをここで解説するのは大変なので、重要な部分だけを抜粋していきます。
本記事で示すコードスニペットは、実際のソースコードから一部を抜粋・編集したものです。詳細は公式リポジトリを参照してください。

### 組み込みモジュールの登録

まず、組み込みモジュール（`print`関数を含む`builtins`モジュール）が初期化され、インタプリタに登録されます。

```c:Python/pylifecycle.c

static PyStatus
pycore_init_builtins(PyThreadState *tstate)
{
    // ...
    // builtinsモジュール
    PyObject *bimod = _PyBuiltin_Init(interp);
    // ...
    // builtinsモジュールの辞書オブジェクトを取得
    PyObject *builtins_dict = PyModule_GetDict(bimod);
    // ...
    // インタプリタの組み込み名前空間に登録
    interp->builtins = Py_NewRef(builtins_dict);
    // ...
}
```

ここで呼び出されている `_PyBuiltin_Init` は、`Python/bltinmodule.c` に定義されています。

### 組み込み関数の登録

この関数で、モジュールを作成している箇所があります。

```c:Python/bltinmodule.c
PyObject *
_PyBuiltin_Init(PyInterpreterState *interp)
{
    // ...

    mod = _PyModule_CreateInitialized(&builtinsmodule, PYTHON_API_VERSION);

    // ...
}
```

元となっている`builtinsmodule`を見てみましょう。
ここに、`print`や`len`といった組み込み関数のエントリが並んでいます。

```c:Python/bltinmodule.c
static struct PyModuleDef builtinsmodule = {
    builtin_methods,
};

static PyMethodDef builtin_methods[] = {
    // input関数
    BUILTIN_INPUT_METHODDEF
    
    // len関数
    BUILTIN_LEN_METHODDEF

    // max、min関数
    {"max", _PyCFunction_CAST(builtin_max), METH_FASTCALL | METH_KEYWORDS, max_doc},
    {"min", _PyCFunction_CAST(builtin_min), METH_FASTCALL | METH_KEYWORDS, min_doc},
    
    // print 関数が登録されている！
    BUILTIN_PRINT_METHODDEF
};
```

さらに`BUILTIN_PRINT_METHODDEF`の定義を辿っていきます。

```c:Python/bltinmodule.c
#define BUILTIN_PRINT_METHODDEF    \
    {"print", _PyCFunction_CAST(builtin_print), METH_FASTCALL|METH_KEYWORDS, builtin_print__doc__},
```

これはC言語の「マクロ」という機能で、`BUILTIN_PRINT_METHODDEF`の部分を、後に続くコードに置き換えます。
いろいろと書いてありますが、重要なのは`builtin_print`という関数で、これが`print`関数の本体です。

### `builtin_print`関数

ようやく`print`関数のC言語実装にたどり着きました。
重要な部分を抜粋して紹介します。

この関数には、モジュールオブジェクトと、Python 側から渡された引数（位置引数・キーワード引数）がまとめて渡されます。

```c
static PyObject *
builtin_print(PyObject *module, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames)
{
```

`print`関数のキーワード引数はここで処理されているんですね。
`print`関数では、`file`で指定されたファイルに対して出力を行ったり、`end`で末尾に付ける文字列を指定したりできます。
Pythonだと、引数を指定しないとデフォルト値が使われるように振る舞いますが、C言語側では、`None`にしてから、デフォルト値を設定しています。

```c
    static const char * const _keywords[] = {"sep", "end", "file", "flush", NULL};
```

引数はデフォルト値ではなく、`None`で初期化されます。

```c
    PyObject *sep = Py_None;
    PyObject *end = Py_None;
    PyObject *file = Py_None;
    int flush = 0;
```

これは、このラッパー関数が自動生成されているためです。
CPythonの実装では、組み込み関数の引数処理に`Argument Clinic`というツールが使われています。引数のパースはこの関数で、実際のロジックは`builtin_print_impl`で行う、という形になっています。

```c
    return_value = builtin_print_impl(module, __clinic_args, args_length, sep, end, file, flush);
```

この`builtin_print_impl`関数が、実際に出力を行う部分です。

```c:Python/bltinmodule.c
static PyObject *
builtin_print_impl(PyObject *module, PyObject * const *args,
                   Py_ssize_t args_length, PyObject *sep, PyObject *end,
                   PyObject *file, int flush)
{
```
`Hello, world!`では`file`引数を指定しないため、デフォルトで標準出力（`sys.stdout`）に出力されます。

```c
    if (file == Py_None) {
        file = _PySys_GetRequiredAttr(&_Py_ID(stdout));
    }
```

そして、`for`ループで引数を一つずつ文字列に変換して出力します。

```c
for (i = 0; i < args_length; i++) {
    if (i > 0) {
        if (sep == NULL) {
            err = PyFile_WriteString(" ", file);
        }
        else {
            err = PyFile_WriteObject(sep, file, Py_PRINT_RAW);
        }
        if (err) {
            Py_DECREF(file);
            return NULL;
        }
    }

    // Py_PRINT_RAW は「引用符などを付けずにそのまま出力せよ」というフラグ
    // ここで引数を出力している
    err = PyFile_WriteObject(args[i], file, Py_PRINT_RAW);
    if (err) {
        Py_DECREF(file);
        return NULL;
    }
}
```

文字列の最後に任意の文字列を追加する`end`引数は、値が指定されていない場合は改行を出力します。

```c
if (end == NULL) {
    err = PyFile_WriteString("\n", file);
}
```

`PyFile_WriteObject`はファイルオブジェクトの`write`メソッドを呼び出します。

```c
int
PyFile_WriteObject(PyObject *v, PyObject *f, int flags)
{
    PyObject *writer, *value, *result;

    writer = PyObject_GetAttr(f, &_Py_ID(write));
    result = PyObject_CallOneArg(writer, value);
```

こういうのは「ダックタイピング」と呼ばれるみたいです。クラス名・型名ではなく、そのオブジェクトが持っているメソッドや振る舞いに注目して、「この処理で使えるかどうか」を判断する考え方です。以下の記事が詳しいです（英語）。

https://realpython.com/duck-typing-python/

すなわち、ここでは`stdout`オブジェクトの`write`メソッドが呼び出されると思われますね。
それでは、このオブジェクトの実装を探っていくことにしましょう。

### `sys.stdout`オブジェクト

`init_sys_streams`関数では、標準入出力が初期化されます。

```c:Python/pylifecycle.c
static PyStatus
init_sys_streams(PyThreadState *tstate)
{
    // stdoutのファイルディスクリプタを取得
    fd = fileno(stdout);
    // TextIOWrapper
    std = create_stdio(config, iomod, fd, 1, "<stdout>",
                       config->stdio_encoding,
                       config->stdio_errors);

    // 登録している！

    // ユーザーがstdoutを上書きしたときのバックアップ
    PySys_SetObject("__stdout__", std);
    
    // sys.stdout
    _PySys_SetAttr(&_Py_ID(stdout), std);
```

ファイルディスクリプタから`TextIOWrapper`オブジェクトが作成され、`sys.stdout`に登録されているようです。

ファイルディスクリプタは、UNIX系OSがファイル・ディレクトリ・ソケット・端末・デバイスなどの「ファイルっぽいもの」を一元的に扱うための仕組みです。
標準出力はファイルディスクリプタの番号`1`に対応しています。`0`は標準入力、`2`は標準エラー出力です。

`TextIOWrapper`オブジェクトは、テキスト入出力を扱うためのラッパークラスです。このオブジェクトが、実際に文字列を書き込むための`write`メソッドを持っています。その実装を見てみましょう。

`builtin_print`の時と同様に、引数処理と実装が分かれています。

```c:Modules/_io/clinic/textio.c.h
static PyObject *
_io_TextIOWrapper_write(PyObject *self, PyObject *arg)
{
    // 引数処理

    return_value = _io_TextIOWrapper_write_impl((textio *)self, text);
```

```c:Modules/_io/textio.c
static PyObject *
_io_TextIOWrapper_write_impl(textio *self, PyObject *text)
{
```

この関数は実装が大きいため、要点を抜粋して紹介します。

まず、この関数は文字列をバイト列に変換し、`pending_bytes`というバッファに溜め込みます。そして、バッファがいっぱいになったり、フラッシュが要求されたりしたときに、実際の書き込み処理を行います。
フラッシュとは、バッファに溜め込んだデータを出力先に書き出す操作のことです。

実は`TextIOWrapper`は、さらに下位に`BufferedWriter`というバッファリング用のオブジェクトを持っており、最終的にはそこにデータを書き込み、OSに渡されます。
したがって、バッファは2つあり、フラッシュも2種類あります。

1. `TextIOWrapper`の`pending_bytes`バッファを`BufferedWriter`に書き込むフラッシュ
2. `pending_bytes`を`BufferedWriter`に書き込み、さらに`BufferedWriter`をフラッシュしてOSにデータを書き込むフラッシュ

まず、巨大なデータなら先にフラッシュします。こちらは下位層に書き込むフラッシュです。

```c
if (bytes_len >= self->chunk_size) {
    while (self->pending_bytes != NULL) {
        if (_textiowrapper_writeflush(self) < 0) {
            // ...
        }
    }
}
```

この`pending_bytes`は、リストになっています。細かい書き込みを複数回行うとパフォーマンスが悪化するため、ある程度まとめてから出力するようになっています。

そして、バッファにデータを追加します。

```c
if (self->pending_bytes == NULL) {
    self->pending_bytes = b;
}
else if (!PyList_CheckExact(self->pending_bytes)) {
    PyObject *list = PyList_New(2);

    self->pending_bytes = list;
```

データが一つならそのままセット、複数ならリストにまとめる、という実装ですね。
そして、`pending_bytes`のサイズを更新します。

```c
self->pending_bytes_count += bytes_len;
```

最後に、必要に応じてフラッシュを行います。フラッシュを行うのは以下の場合です。

- 溜め込んだ量が`chunk_size`を超えたとき
- 行バッファリングが有効で、`"\n"`が来たとき
- 即時書き込みの設定がされているとき

ここでも、下位層のバッファ`self->buffer`に書き込まれます。

```c
if (self->pending_bytes_count >= self->chunk_size || needflush ||
    text_needflush) {
    if (_textiowrapper_writeflush(self) < 0)
        return NULL;
}
```

その直後にあるこの処理は、自分も、下位層もフラッシュして、OSへデータを書き込む部分です。
行ごとに出力を行う「行バッファリング」が有効な状態で改行が来たときは、即座に書き込むようになっています。
人間にとっては行ごとに表示するのが自然なため、ターミナルの標準出力は通常このモードになっています。
ファイルに書き込む場合は、通常のバッファリングモードになります。

```c
if (needflush) {
    if (_PyFile_Flush(self->buffer) < 0) {
        return NULL;
    }
}
```

通常、`Hello, world!`はコマンドラインで実行されるため、行バッファリングモードで動作します。したがって、改行が来た時点でOSにデータが書き込まれます。`_PyFile_Flush`関数は、下位層の`BufferedWriter`オブジェクトの`flush`メソッドを呼び出します。

### BufferedWriterオブジェクト

定義にジャンプを繰り返していくと、フラッシュの処理にたどり着きます。

```c:Modules/_io/bufferedio.c
static PyObject *
_io__Buffered_flush_impl(buffered *self)
{
    PyObject *res;
    res = buffered_flush_and_rewind_unlocked(self);
}
```

```c:Modules/_io/bufferedio.c
static PyObject *
buffered_flush_and_rewind_unlocked(buffered *self)
{
    PyObject *res;
    res = _bufferedwriter_flush_unlocked(self);
```

↓ここですね。

```c:Modules/_io/bufferedio.c
    static PyObject *
_bufferedwriter_flush_unlocked(buffered *self)
{
    while (self->write_pos < self->write_end) {
        // self.rawのwriteが呼ばれる
        // raw（self.raw）とは、FileIO のこと
        n = _bufferedwriter_raw_write(self,
            self->buffer + self->write_pos,
            Py_SAFE_DOWNCAST(self->write_end - self->write_pos,
                             Py_off_t, Py_ssize_t));
        
        self->write_pos += n;
        self->raw_pos = self->write_pos;
    }
}

```

バッファの中身をひたすら書き出しています。`_bufferedwriter_raw_write`の中で`self->raw`の`write`メソッドが呼び出され、最終的にOSにデータが渡されます。
ここでは、`raw`というのは`FileIO`オブジェクトのことを指します。
名前からして、標準出力のファイルディスクリプタに直接書き込む役割を持っていそうですね。

### FileIO.writeメソッド

こちらが実装です。

```c:Modules/_io/fileio.c
static PyObject *
_io_FileIO_write_impl(fileio *self, PyTypeObject *cls, Py_buffer *b)
{
    Py_ssize_t n;
    n = _Py_write(self->fd, b->buf, b->len);
```

`_Py_write`という関数は以下の`_write_impl`を呼び出しています。
この関数こそが、C言語のランタイム（libc）の`write`関数を呼び出し、OSにデータを書き込む部分です。

```c:Python/fileutils.c
static Py_ssize_t
_Py_write_impl(int fd, const void *buf, size_t count, int gil_held)
{
```

書き込みでは、GIL（Global Interpreter Lock）が保持されているかどうかを確認しています。
これは同時に複数のスレッドがPythonオブジェクトにアクセスするのを防ぐための仕組みです。Python バイトコードを実行するときは1スレッドだけになるようロックすることで、スレッドセーフを実現しています。

ファイル書き込みはI/O操作であり、CPUにとっては非常に長い待ち時間が発生する可能性があります。したがって、書き込み中はGILを解放し、他のスレッドがPythonオブジェクトにアクセスできるようにしています。

例えば、大量のログを出力している最中でも、Webサーバーのリクエスト処理など、他のスレッドが止まらずに動けるようになります。

```c
    if (gil_held) {
        do {
            Py_BEGIN_ALLOW_THREADS // 解放！

            // libcのwrite関数を呼び出している！
            n = write(fd, buf, count);
            
            Py_END_ALLOW_THREADS // スレッドを再取得
        } while (n < 0 && err == EINTR &&
                !(async_err = PyErr_CheckSignals()));
    }
    else {
        // シグナルが来ると中断されることがある
        // その場合は再度行う
        // ただし、Ctrl + C(SIGINT)はPythonでハンドリングされエラーになる
        do {
            n = write(fd, buf, count);
        } while (n < 0 && err == EINTR);
    }

    return n;
}
```

ありましたね。`n = write(fd, buf, count);`と書かれています。この`write`は、C言語の標準ライブラリで定義されているものです。通常は GNU Cライブラリ（glibc）に含まれている実装が使われます。これは動的リンクされているため、CPython自体のバイナリには含まれていません。実行環境にインストールされているlibc（たとえば、GNU Cライブラリ/glibc）の実装が使われます。

というわけで、ついにPythonの世界からC言語の標準ライブラリに到達しました。あとはlibcがOSカーネルにシステムコールを発行して、OSが処理を行います。

## おわりに

一行のシンプルなプログラムでも、裏側では多くの層が連携して動作していることが分かりましたね。
こういう実装の深掘りは、コードを読む練習にもなり、言語のランタイムやOSの仕組みを理解する助けにもなります。
GILやバッファリング、システムコールといった概念を、副産物として一緒に学べたのも大きな収穫です。

こういう感じで実装を覗くのは、学べることが多いので今後もやっていきたいですね。

本記事は「KDIX CS Advent Calendar 2025」に参加しています。

https://qiita.com/advent-calendar/2025/kdixcs

## シリーズの紹介

本記事は「Hello World のひみつ」シリーズの Python 編です。
すでに公開している Rust 編では、`println!` から `libc::write` までの流れを追いかけています。

https://blog.pullriku.net/posts/inside-hello-world-rust/

