---
title: Brainfuckコンパイラを作った　LLVMを使って
emoji: 🧠
type: tech
topics:
- Rust
- LLVM
- brainfuck
- inkwell
- コンパイラ
published: true
---

## はじめに
本記事はRust言語で作成した[Brainfuck](https://ja.wikipedia.org/wiki/Brainfuck)コンパイラの紹介です。ネイティブにコンパイルされ、最適化が効くので、高速に動作します。

![](https://storage.googleapis.com/zenn-user-upload/9d694cd1118c-20240316.gif)

### GitHubリポジトリ

本記事で紹介するプログラムの完成品は以下のリポジトリで公開しています。本記事で解説していない部分（インタプリタなど）も含まれます。
https://github.com/pullriku/brainfuck-rs

### 環境
```sh
# macOSのバージョン
$ sw_vers
ProductName:            macOS
ProductVersion:         14.4
BuildVersion:           23E214

# Rustコンパイラのバージョン
$ rustc --version
rustc 1.75.0 (82e1608df 2023-12-21)

# Cargoのバージョン
$ cargo --version
cargo 1.75.0 (1d8b05cdd 2023-11-20)

# clangのバージョン
$ clang --version
Homebrew clang version 17.0.6
Target: arm64-apple-darwin23.4.0
Thread model: posix
InstalledDir: /opt/homebrew/opt/llvm/bin

# LLVMのバージョン
$ llvm-config --version
17.0.6
```
- MacBook Pro 2021 (M1 Pro) を使用しています。
- これ以降に示すRustプログラムは、Rust 2021エディションです。


## 字句解析・構文解析
Brainfuckには命令が8個しかなく、全ての命令は1文字なので、簡単に実装できます。詳細は省略します。全ての実装を参照したい場合は上で示したGitHubのリポジトリを確認してみてください。関係のあるファイルは`src/`の
```txt
token.rs
scanner.rs
parser.rs
ast.rs
```
です。

最終的に以下のenumのベクタ`Vec<Instruction>`を生成し、これをプログラムとします。

```rust:ast.rs
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Instruction {
    InclementPointer,
    DecrementPointer,
    InclementValue,
    DecrementValue,
    Output,
    Input,
    Loop(Vec<Instruction>),
}
```

## LLVM IRへのコンパイル
ここからが本題です。ソースコードは上で示したリポジトリの`src/llvm/compiler.rs`にあります。

### 事前準備
LLVMの中間表現「LLVM IR」を生成していきます。LLVMはC 言語のAPIを提供しており、これのRustラッパーとして[`llvm-sys`](https://crates.io/crates/llvm-sys)クレートがあります。本記事では、この`llvm-sys`を抽象化し、安全に使えるように設計された[`inkwell`](https://crates.io/crates/inkwell/)クレートを使います。また、複数のエラー型を扱うために[`anyhow`](https://crates.io/crates/anyhow/)クレートを使います。`Cargo.toml`のdependenciesは次の通りです。

```toml:Cargo.toml
[dependencies]
anyhow = "1.0.80"
inkwell = { version = "0.4.0", features = ["llvm17-0"] }
```

`inkwell`にLLVMのバージョンに合ったfeatureを指定してください。私の場合は`17.0.6`がインストールされているので、`"llvm17-0"`を指定しています。また、`LLVM_SYS_170_PREFIX`のような環境変数がないというエラーが出ることがあります。その場合は環境変数`LLVM_SYS_バージョン_PREFIX`に`llvm`ディレクトリの場所を指定してください。私の場合は以下のようにしました。
```sh:~/.zshrc
export LLVM_SYS_170_PREFIX=/opt/homebrew/opt/llvm
```

### inkwellの準備
インポートです。
```rust:compiler.rs
use std::io::Write;
use std::path::Path;

use anyhow::{anyhow, Ok, Result};
use inkwell::builder::Builder;
use inkwell::context::Context;
use inkwell::module::Module;
use inkwell::types::{FunctionType, IntType, PointerType};
use inkwell::values::{AnyValue, FunctionValue, GlobalValue, IntValue, PointerValue};
use inkwell::{targets, AddressSpace, IntPredicate};

use crate::ast::Instruction;
```

これ以降に使用する構造体です。
```rust:compiler.rs
#[derive(Debug)]
pub struct Compiler<'ctx> {
    context: &'ctx Context,
    module: Module<'ctx>,
    builder: Builder<'ctx>,
    machine: targets::TargetMachine,

    types: Types<'ctx>,
    values: Values<'ctx>,
}

#[derive(Debug)]
struct Types<'ctx> {
    i8_ptr_type: PointerType<'ctx>,
    i8_type: IntType<'ctx>,
    i32_type: IntType<'ctx>,
    getchar_fn_type: FunctionType<'ctx>,
    putchar_fn_type: FunctionType<'ctx>,
    printf_fn_type: FunctionType<'ctx>,
    main_fn_type: FunctionType<'ctx>,
}

#[derive(Debug)]
#[allow(dead_code)]
struct Values<'ctx> {
    getchar_fn: FunctionValue<'ctx>,
    putchar_fn: FunctionValue<'ctx>,
    printf_fn: FunctionValue<'ctx>,
    main_fn: FunctionValue<'ctx>,

    msg_ptr: GlobalValue<'ctx>,
    pointer_ptr: PointerValue<'ctx>,
}
```

`Context`はコンパイルの全体を表します。`Module`はコンパイルの単位です。`Builder`は`Module`に対して命令を追加するための構造体です。`TargetMachine`はLLVMのターゲットマシンを表します。

`Context`と`Module`・`Builder`は紐づいており、以下のようにして生成します。型の情報など、コンパイル全体に関係する操作は`Context`から呼び出せます。関数の生成など、コンパイル単位に関係する操作は`Module`から呼び出せます。命令の追加は`Builder`から呼び出せます。
```rust:例
let context = Context::create();
let module = context.create_module("main");
let builder = context.create_builder();
```

コンパイラを生成するための`new`関連関数を作りましょう。

```rust:compiler.rs
impl<'ctx> Compiler<'ctx> {
    pub fn new(context: &'ctx Context, machine: targets::TargetMachine) -> Self {
        let module = context.create_module("main");
        let builder = context.create_builder();

        let types = Types {
            i8_ptr_type: context.i8_type().ptr_type(AddressSpace::default()),
            i8_type: context.i8_type(),
            i32_type: context.i32_type(),
            getchar_fn_type: context.i8_type().fn_type(&[], false),
            putchar_fn_type: context
                .i32_type()
                .fn_type(&[context.i8_type().into()], false),
            printf_fn_type: context.i32_type().fn_type(
                &[context.i8_type().ptr_type(AddressSpace::default()).into()],
                true,
            ),
            main_fn_type: context.i32_type().fn_type(&[], false),
        };

        let main_fn = module.add_function("main", types.main_fn_type, None);
        let entry_block = context.append_basic_block(main_fn, "entry_block");
        builder.position_at_end(entry_block);

        let array_type = types.i8_type.array_type(30000);
        let array_value = array_type.const_zero();

        let array = builder.build_alloca(array_type, "array").unwrap();
        builder.build_store(array, array_value).unwrap();

        let pointer_ptr = builder
            .build_alloca(types.i8_ptr_type, "pointer")
            .unwrap();

        builder
            .build_store(pointer_ptr, array)
            .unwrap();

        let msg_ptr = builder.build_global_string_ptr("[%p]", "message").unwrap();

        let values = Values {
            getchar_fn: module.add_function("getchar", types.getchar_fn_type, None),
            putchar_fn: module.add_function("putchar", types.putchar_fn_type, None),
            printf_fn: module.add_function("printf", types.printf_fn_type, None),
            main_fn,
            msg_ptr,
            pointer_ptr,
        };

        Self {
            context,
            module,
            builder,
            machine,
            types,
            values,
        }
    }
}
```

`types`には型の情報をまとめてあります。`IntType`の`ptr_type`メソッドを呼び出すと、その型のポインタ型を生成できます。
関数については、`getchar`や`printf`のように、C言語の`libc`と同名の関数が用意されています。加えて、自分で`main`関数を定義し、Brainfuckの処理はここに書き込んでいきます。
`entry_block`は`main`関数の最初のブロックです。ブロックについては後に説明します。
`array`はBrainfuckで使う配列へのポインタです。
`pointer_ptr`は`array`のポインタです。つまり、配列へのポインタのポインタです。
`msg_ptr`はデバッグ用です。プリントデバッグをするときに使います。

`alloca`命令は領域を確保し、そこへのポインタを返します。`store`命令はポインタの指すところに値を格納します。

次からは命令のコンパイルを行っていきます。

### `>`のコンパイル
新しいメソッドを作って、処理を書き込みましょう。

（`impl<'ctx> Compiler<'ctx>`に追記する）
```rust:compiler.rs
fn compile_instruction(&mut self, instruction: Instruction) {
    match instruction {
        Instruction::InclementPointer => {
            let pointer = self.load_ptr(self.values.pointer_ptr);

            let new_pointer = unsafe {
                self.builder
                    .build_in_bounds_gep(
                        self.types.i8_ptr_type,
                        pointer,
                        &[self.types.i32_type.const_int(1, false)],
                        "incremented_pointer",
                    )
                    .unwrap()
            };

            self.builder
                .build_store(self.values.pointer_ptr, new_pointer)
                .unwrap();
        }
    }
}

/// i8 ptr ptr -> i8 ptr
fn load_ptr(&self, ptr_ptr: PointerValue<'ctx>) -> PointerValue<'ctx> {
    self.builder
        .build_load(self.types.i8_ptr_type, ptr_ptr, "pointer")
        .unwrap()
        .into_pointer_value()
}

/// i8 ptr -> i8
fn load_value(&self, ptr: PointerValue<'ctx>) -> IntValue<'ctx> {
    self.builder
        .build_load(self.types.i8_type, ptr, "value")
        .unwrap()
        .into_int_value()
}
```

`>`はポインタを1だけインクリメントする命令です。
`load_ptr`で配列の値へのポインタを取得し、それを`i8`型のサイズだけインクリメントします。
`store`命令で`pointer_ptr`に新しいポインタを格納します。
`build_in_bounds_gep`の`GEP`は`getelementptr`の略です。アドレスを計算するのに使います。

### `<`のコンパイル

（`fn compile_instruction`の`match`に追記する）
```rust:compiler.rs
Instruction::DecrementPointer => {
    let one = self.types.i32_type.const_int(1, false);
    let diff = self.builder.build_int_neg(one, "minus_one").unwrap();

    let pointer = self.load_ptr(self.values.pointer_ptr);

    let new_pointer = unsafe {
        self.builder
            .build_in_bounds_gep(
                self.types.i8_ptr_type,
                pointer,
                &[diff],
                "decremented_pointer",
            )
            .unwrap()
    };

    self.builder
        .build_store(self.values.pointer_ptr, new_pointer)
        .unwrap();
}
```
`<`はポインタを1だけデクリメントする命令です。`>`と同様にします。
`const_int`の引数の型が`u64`なので、負の値を渡すことができません。そのため、1を渡して、`build_int_neg`で`-1`を作っています。

### `+`のコンパイル

（`fn compile_instruction`の`match`に追記する）
```rust:compiler.rs
Instruction::InclementValue => {
    let pointer = self.load_ptr(self.values.pointer_ptr);

    let value = self.load_value(pointer);

    let new_value = self
        .builder
        .build_int_add(
            value,
            self.types.i8_type.const_int(1, false),
            "incremented_value",
        )
        .unwrap();
    self.builder.build_store(pointer, new_value).unwrap();
}
```
`+`はポインタの指す値を1増やす命令です。
ポインタのポインタを2回`load`して、値を取得します。値に1を加えて、結果を`store`します。

### `-`のコンパイル

（`fn compile_instruction`の`match`に追記する）
```rust:compiler.rs
Instruction::DecrementValue => {
    let pointer = self.load_ptr(self.values.pointer_ptr);

    let value = self.load_value(pointer);

    let new_value = self
        .builder
        .build_int_sub(
            value,
            self.types.i8_type.const_int(1, false),
            "decremented_value",
        )
        .unwrap();
    self.builder.build_store(pointer, new_value).unwrap();
}
```
`-`はポインタの指す値を1減らす命令です。`+`と同様にします。

### `.`のコンパイル

（`fn compile_instruction`の`match`に追記する）
```rust:compiler.rs
Instruction::Output => {
    let pointer = self.load_ptr(self.values.pointer_ptr);

    let value = self.load_value(pointer);
    self.builder
        .build_call(self.values.putchar_fn, &[value.into()], "call_putchar")
        .unwrap();
}
```
`.`はポインタの指す値を出力する命令です。`putchar`関数を呼び出します。

### `,`のコンパイル

（`fn compile_instruction`の`match`に追記する）
```rust:compiler.rs
Instruction::Input => {
    let value = self
        .builder
        .build_call(self.values.getchar_fn, &[], "call_getchar")
        .unwrap()
        .as_any_value_enum()
        .into_int_value();
    let pointer = self.load_ptr(self.values.pointer_ptr);
    self.builder.build_store(pointer, value).unwrap();
}
```

`,`は入力を読み取り、ポインタの指す値に格納する命令です。`getchar`関数を呼び出します。

### `[]`のコンパイル

#### BasicBlockとbuilderのpositionについて
LLVM IR上で、あるラベルからその次のラベルまで（その次のラベルは含まない）が一つのBasicBlockとして扱われます。各BasicBlockの最後にはterminatorが含まれます。これには、他のブロックに分岐する`br`命令や、関数を抜ける`ret`命令が該当します。

```llvm
define i32 @main() {
    block1:
        ; ブロック1
        br label %block2 ; （terminator）block2へ移動
    block2:
        ; ブロック2
        ret i32 0 ; （terminator）関数を抜ける
}
```

`inkwell`では、`Builder::position_at_end`メソッドなどの`position_...`メソッドが提供されています。これらを使って、どのブロックの命令をビルドするかを変更することができます。

#### 実装

一番コード量が多い部分です。

（`fn compile_instruction`の`match`に追記する）
```rust:compiler.rs
Instruction::Loop(instructions) => {
    let loop_start = self
        .context
        .append_basic_block(self.values.main_fn, "loop_start");
    let loop_body = self
        .context
        .append_basic_block(self.values.main_fn, "loop_body");

    self.builder.build_unconditional_branch(loop_start).unwrap();

    self.builder.position_at_end(loop_body);

    for instruction in instructions {
        self.compile_instruction(instruction);
    }

    let before_end = self.values.main_fn.get_last_basic_block().unwrap();
    let loop_end = self
        .context
        .append_basic_block(self.values.main_fn, "loop_end");

    self.builder.position_at_end(loop_start);
    let pointer = self
        .builder
        .build_load(self.types.i8_ptr_type, self.values.pointer_ptr, "pointer")
        .unwrap()
        .into_pointer_value();

    let value = self.load_value(pointer);

    let condition = self
        .builder
        .build_int_compare(
            IntPredicate::NE,
            value,
            self.types.i8_type.const_zero(),
            "condition",
        )
        .unwrap();

    self.builder
        .build_conditional_branch(condition, loop_body, loop_end)
        .unwrap();

    self.builder.position_at_end(before_end);

    self.builder.build_unconditional_branch(loop_start).unwrap();

    self.builder.position_at_end(loop_end);
}
```

Brainfuckの`[]`はC言語風に書くと以下のようになります。
```c
while (*pointer != 0) {}
```

これをブロックで表現すると以下のようになります。
```llvm
    br label %loop_start
loop_start:
    %condition = ポインタの指す値が0ではない
    br i1 %condition, label %loop_body, label %loop_end
loop_body:
    ブロック内の命令
    br label %loop_start
loop_end:
    ...
```

`loop_start`が条件を判定する部分です。ポインタの指す値が0でないなら`loop_body`に移動し、そうでないなら`loop_end`に移動します。
`loop_body`の命令を実行し終わったら、`loop_start`に戻ります。いずれ`loop_end`に移動し、ループを抜けることになります。ラベル（ブロック）と分岐を使ってループを実装することができました。また、全ての命令を実装することができました。

### プログラムのコンパイル

上で作成した`compile_instruction`メソッドは「一つの命令」をコンパイルします。プログラムをコンパイルするには、これを複数回呼び出す必要があります。

（`impl<'ctx> Compiler<'ctx>`に追記する）
```rust:compiler.rs
pub fn compile(&mut self, code: Vec<Instruction>) {
    for instruction in code {
        self.compile_instruction(instruction);
    }

    self.builder
        .position_at_end(self.values.main_fn.get_last_basic_block().unwrap());
    self.builder
        .build_return(Some(&self.types.i32_type.const_int(0, false)))
        .unwrap();
}
```

命令を順番にコンパイルします。最後に、正常終了を表す`0`を返します。

## オブジェクトファイルの生成
LLVM IRの構築は完了しました。次に、オブジェクトファイルを生成します。

（`impl<'ctx> Compiler<'ctx>`に追記する）
```rust:compiler.rs
pub fn write_to_file(&self, file: &Path) -> Result<()> {
    self.module
        .verify()
        .map_err(|e| anyhow!("module verification failed: {}", e))?;
    self.machine
        .write_to_file(&self.module, targets::FileType::Object, file)
        .map_err(|e| anyhow!("failed to write object file: {}", e))?;

    let mut ir = std::fs::File::create("a.ll").unwrap();
    ir.write_all(self.module.to_string().as_bytes())?;

    Ok(())
}
```

`verify`メソッドで、LLVM IRが正しく構築されているかを確認します。もし、terminatorがないブロックがあったり、ポインタに対して`.into_int_value()`メソッドを呼び出したりしていたら、エラーになります。最後に`write_to_file`メソッドでオブジェクトファイルを書き出します。また、デバッグ用にLLVM IRを`a.ll`として書き出します。

## ホストマシンの取得

コンパイル時にターゲットマシンを指定する必要があるので、ホストマシンを取得する処理を追加します。

（`main.rs`に追記する）
```rust:main.rs
fn host_machine() -> anyhow::Result<targets::TargetMachine> {
    Target::initialize_native(&targets::InitializationConfig::default())
        .map_err(|e| anyhow!("failed to initialize native target: {}", e))?;

    let triple = TargetMachine::get_default_triple();
    let target =
        Target::from_triple(&triple).map_err(|e| anyhow!("failed to create target: {}", e))?;

    let cpu = TargetMachine::get_host_cpu_name();
    let features = TargetMachine::get_host_cpu_features();

    let opt_level = OptimizationLevel::Aggressive;
    let reloc_mode = RelocMode::Default;
    let code_model = CodeModel::Default;

    target
        .create_target_machine(
            &triple,
            cpu.to_str()?,
            features.to_str()?,
            opt_level,
            reloc_mode,
            code_model,
        )
        .ok_or(anyhow!("failed to create target machine"))
}
```

`OptimizationLevel::Aggressive`の部分で最適化をするように指定しています。最適化をしない場合は`OptimizationLevel::None`を指定してください。

## リンク
オブジェクトファイルをリンクする処理を書いておきます。


（`main.rs`に追記する）
```rust:main.rs
fn link(object: &Path) -> anyhow::Result<PathBuf> {
    let mut output = PathBuf::from(object);
    output.set_extension("out");

    let process = std::process::Command::new("gcc")
        .args(vec![
            object.to_str().unwrap(),
            "-o",
            output.to_str().unwrap(),
        ])
        .output()?;

    if !process.status.success() {
        anyhow::bail!("{}", String::from_utf8_lossy(&process.stderr));
    }

    Ok(output)
}
```

## 動かしてみる
動かしてみます。

インポートです。

（`main.rs`に追記する）
```rust:main.rs
use std::{env, fs::File, io::Read, path::{Path, PathBuf}};

use anyhow::anyhow;
use inkwell::{
    context::Context, targets::{self, CodeModel, RelocMode, Target, TargetMachine}, OptimizationLevel
};
```

私の場合はこれらに加えて、`Scanner`、`Parser`、`Compiler`をインポートしました。

コンパイラを実行する処理を書きます。

（`main.rs`に追記する）
```rust:main.rs
fn main() {
    let file_name = env::args().nth(1).expect("expected file name");
    let mut file = File::open(file_name).expect("failed to open file");
    let mut src = String::new();
    file.read_to_string(&mut src).expect("failed to read file");

    let mut scanner = Scanner::new(src.chars().collect());
    let tokens = scanner.scan_tokens();

    let parser = Parser::new(tokens);
    let parse_result = parser.parse_tokens();
    let Ok(program) = parse_result else {
        for error in parse_result.unwrap_err() {
            eprintln!("{}", error);
        }
        panic!("failed to parse tokens");
    };

    let context = Context::create();
    let machine = host_machine().expect("failed to create machine");
    let mut compiler = llvm::compiler::Compiler::new(&context, machine);
    compiler.compile(program);
    compiler.write_to_file(Path::new("a.o")).unwrap();

    let _object_path = link(Path::new("a.o")).unwrap();
}
```
`let context = Context::create();`の行までは、プログラム`Vec<Instruction>`を生成するため処理です。
コンパイルを終えると、オブジェクトファイル`a.o`が生成され、それをリンクして実行ファイル`a.out`が生成されます。
ターミナルで`./a.out`を実行すると、Brainfuckプログラムが実行されます。


以下は「Hello, Brainfuck Compiler!」を表示するプログラムです。
```bf:hello.b
+++++++[>++++++++++<-]>++.<++[>++++++++++<-]>+++++++++.+++++++..+++.
<++++++[>----------<-]>-------.<+[>----------<-]>--.<+++[>++++++++++<-]>++++.
<++++[>++++++++++<-]>++++++++.<+[>----------<-]>-------.++++++++.+++++.
--------.<+[>++++++++++<-]>+++++.<+[>----------<-]>--------.++++++++.
<+++++++[>----------<-]>-----.<+++[>++++++++++<-]>+++++.
<++++[>++++++++++<-]>++++.--.+++.-------.+++.-------.<+[>++++++++++<-]>+++.
<++++++++[>----------<-]>-.
```

コンパイルして実行します。

```sh
cargo run -- hello.b
```
```sh
./a.out
```

実行結果です。

```bf:hello.b
Hello, Brainfuck Compiler!
```

コンパイラを作成することができました。


## 参考文献

Gif画像で動かしているプログラム`mandelbrot.b`です。
http://esoteric.sange.fi/brainfuck/utils/mandelbrot/

terminatorについて参考にさせていただきました。
https://www.quora.com/How-do-Terminators-work-in-the-LLVM-IR

「ホストマシンの取得」、「リンク」の部分のコードを参考にさせていただきました。私の実装では一部簡略化した部分があります。
https://qiita.com/_53a/items/d7d4e4fc250bfd945d9e

`inkwell`のドキュメントです。
https://thedan64.github.io/inkwell/inkwell/index.html

LLVM Language Reference Manualです。
https://releases.llvm.org/17.0.1/docs/LangRef.html


## 変更履歴

- 2024-03-17: 「リンク」の「以下の記事を参考にさせていただきました。簡略化してあります。」を削除。
- 2024-03-20: #の数を変更。インポート部を変更。arrayをローカル変数に変更。Valuesからarrayを削除。一部の解説を変更。など
- 2024-03-21: 変更履歴を追加。「はじめに」を変更。
