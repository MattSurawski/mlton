# Proposal for using LLVM's C API for codegen in MLton
## Motivation
Currently MLton's `--codegen llvm` option produces LLVM IR in a textual format before compiling it with `llc`. This codegen path was originally written by Brian Leibig for his Master's project; the report can be found here https://www.cs.rit.edu/~mtf/student-resources/20124_leibig_msproject.pdf. Leibig made the choice to generate textual IR in order to make developing the codegen easier. Generating text is consistent with the other codegens, minimizing the amount of changes that needed to be made to existing MLton code. Being able to read the LLVM IR also has its advantages when debugging.

The alternative way to generate LLVM IR is to build an in-memory representation using LLVM's C API and emitting it as bitcode. This has a few potential advantages over generating textual IR. The first is compatibility between versions of LLVM. There have been breaking changes to the IR in the past that would require changes to codegen that generates text directly. The C API is probably more stable, increasing the likelyhood that LLVM could be upgraded without requiring changes to the codegen. Another potential advantage is the analysis and optimization that can be performed on the in-memory representation of LLVM. The Analysis library http://llvm.org/docs/doxygen/html/c_2Analysis_8h_source.html provides four useful functions; two for verifying modules and functions and two for viewing the control flow graph of functions. The Scalar module http://llvm.org/test-doxygen/api/c_2Transforms_2Scalar_8h.html provides a set of optimization passes that can be applied to the in-memory representation. LLVM also provides a just-in-time (JIT) compiler for the in-memory representation of a program. This doesn't have any obvious uses in MLton yet, but it has the potential to be used for something like a REPL in the future. 

## Implementing the Codegen
### Linking with the LLVM libraries
Only a simple change is needed in order to link MLton with the LLVM libraries. Here is a diff:

```
diff --git a/mlton/Makefile b/mlton/Makefile
index 332f206..c827ccb 100644
--- a/mlton/Makefile
+++ b/mlton/Makefile
@@ -24,6 +24,7 @@ ifeq (self, $(shell if [ -x "$(BIN)/mlton" ]; then echo self; fi))
   FILE := mlton.mlb
   FLAGS += -default-ann 'sequenceNonUnit warn'
   FLAGS += -default-ann 'warnUnused true'
+  FLAGS += -link-opt "$(shell llvm-config --libs core bitwriter) $(shell llvm-config --libs --cflags --ldflags core bitwriter) -lstdc++"
   # FLAGS += -type-check true
 else
 # We're compiling MLton with an older version of itself. 
```

Note the MLton uses `gcc` for linking. LLVM libraries are written in C++, so `gcc` needs to link against the C++ standard library using the `-lstdc++` flag.

### Calling LLVM from MLton
#### Enabling the FFI
A couple changes need to be made to sources.mlb in order to call LLVM functions. `allowFFI` needs to be set to true for the files that call LLVM functions. `../../..basis-library/mlton.mlb` needs to be included in order to use MLton's pointer type. Here is a diff:

```
diff --git a/mlton/codegen/llvm-codegen/sources.mlb b/mlton/codegen/llvm-codegen/sources.mlb
index 7d10ec7..191be72 100644
--- a/mlton/codegen/llvm-codegen/sources.mlb
+++ b/mlton/codegen/llvm-codegen/sources.mlb
@@ -10,9 +10,14 @@ local
    ../../backend/sources.mlb
    ../../control/sources.mlb
    ../c-codegen/sources.mlb
+   ../../../basis-library/mlton.mlb
 
+   ann "allowFFI true" in
+      llvm-core.sml
+   end
    llvm-codegen.sig
    llvm-codegen.fun
 in
+   structure LLVMCore
    functor LLVMCodegen
 end
```

#### LLVM Types
LLVM relies heavily on pointers for passing around references to modules, types, values, etc.. MLton treats them all as `MLton.Pointer.t`s, but it is useful to give them unique names.

```
type module_ref = MLton.Pointer.t
type type_ref = MLton.Pointer.t
type type_ref_list = type_ref vector
type value_ref = MLton.Pointer.t
type value_ref_list = value_ref vector
type basic_block_ref = MLton.Pointer.t
type builder_ref = MLton.Pointer.t
...
```

#### LLVM Functions
##### Automatic interface generators
LLVM's C API is large enough to consider using an automatic interface generator, like SWIG http://www.swig.org/. For SWIG in particular there are two prerequisites to using it for LLVM and MLton. The first is creating an interface file for LLVM's C API that SWIG requires as input. This somewhat defeats the purpose of using SWIG because you would have to do the work of finding all the functions you want to use anyways. The second is upgrading SWIG to be able to emit SML code that uses MLton's FFI. From a glance it seems that this would require modifiying SWIG's source and rebuilding SWIG.

##### Importing functions
LLVM functions are called via MLton's foreign function interface http://mlton.org/ForeignFunctionInterface. Documentation for LLVM's C API can be found at http://llvm.org/docs/doxygen/html/group__LLVMC.html. Here is a listing of enough function imports to build a simple LLVM module:

```
val ModuleCreateWithName = _import "LLVMModuleCreateWithName" : string -> module_ref;
val Int32Type = _import "LLVMInt32Type" : unit -> type_ref;
val FloatType = _import "LLVMFloatType" : unit -> type_ref;
val FunctionType = _import "LLVMFunctionType" : type_ref * type_ref_list * word * bool -> type_ref;
val AddFunction = _import "LLVMAddFunction" : module_ref * string * type_ref -> value_ref;
val AppendBasicBlock = _import "LLVMAppendBasicBlock" : value_ref * string -> basic_block_ref;
val CreateBuilder = _import "LLVMCreateBuilder" : unit -> builder_ref;
val PositionBuilderAtEnd = _import "LLVMPositionBuilderAtEnd" : builder_ref * basic_block_ref -> unit;
val GetParam = _import "LLVMGetParam" : value_ref * int -> value_ref;
val BuildAdd = _import "LLVMBuildAdd" : builder_ref * value_ref * value_ref * string -> value_ref;
val BuildRet = _import "LLVMBuildRet" : builder_ref * value_ref -> value_ref;
val BuildCall = _import "LLVMBuildCall" : builder_ref * value_ref * value_ref_list * int * string -> value_ref;
val WriteBitcodeToFile = _import "LLVMWriteBitcodeToFile" : module_ref * string -> int;
val DisposeBuilder = _import "LLVMDisposeBuilder" : builder_ref -> unit;
```

#### Building an LLVM module
##### Type signatures
LLVM IR is typed, so many LLVM functions expect types as arguments. Primatives can be created by calling `LLVMInt32Type()` or `LLVMFloatType`, while more complex types need to be built up. Function types are created by calling `LLVMFunctionType(type_ref, type_ref*, num_args, is_variadic)`. Here is an example of creating a function with type `float -> float`
```
val ftype = FunctionType(FloatType(), Vector.fromList [FloatType()], 0w1, false)
```

##### Function declarations and intrinsics
MLton makes use of several LLVM intrinsic functions. In order to add intrinsics to an LLVM program, simply add a function to a module without giving it a function body like so:
```
val ftype = FunctionType(FloatType(), Vector.fromList [FloatType()], 0w1, false)
val fsqrt = AddFunction(modl, "llvm.sqrt.f32", ftype)

```

##### Basic blocks
Basic blocks are LLVM constructs with a single entrance and exit point. They can be appended to a function in order to act as the functions body like so: `val entry = AppendBasicBlock(sum, "entry")` Basic blocks are constructed using builders. Here is an example of using a builder to build a function that sums its arguments:

```
val builder = CreateBuilder()
val () = PositionBuilderAtEnd(builder, entry)
val tmp = BuildAdd(builder, GetParam(sum, 0), GetParam(sum, 1), "tmp")
val _ = BuildRet(builder, tmp)
```

#### Writing an LLVM module to a file
When you have finished building an LLVM module and want to write it to a file, use the bitwriter module like so:
```
val r = WriteBitcodeToFile(modl, "sum.bc")
val () = DisposeBuilder(builder)
```
If r = 0, then the module was successfully written to bitcode.

### Using the bitcode
Bitcode can be disassembled into textual IR using  `llvm-dis`.

Bitcode can be compiled to an object file using `llc file.bc -filetype=obj`. This object file can then be linked with just like any other object file. 

## Work to be done
Building an in-memory LLVM representation of the program and outputting it to a file at the end is a significantly different process than the current LLVM codegen. Currently the codegen is divided up into functions that are consistent with MLton's internal representation, like `outputChunk`, `outputBlock`, `outputTransfer`, etc. In order to use LLVM's API this would be better restructured into functions like `createModule`, `addFunction`, `addBlock`, and so on. These functions would call out to the LLVM libraries to make references to modules, functions, blocks, etc. and then pass the references into functions to add code to the module, function, or block.

Instead of having a block of text representing intrinsics, types, and other global declarations the new code gen should initialize a global table with references created from LLVM API calls. When the codegen wants to refer to a type or call an intrinsic/global function it would lookup the reference in the global table.

It may be possible to determine the capabilities (namely the supported intrinsics and primatives) of the LLVM version being used at runtime. This would replace the `implementsPrim` function and provide better runtime compatability with older versions of LLVM and enhanced performance with newer versions.

## Exisiting work

A brief report on using LLVM as a backend for SML# https://sites.google.com/site/mlworkshoppe/smlsharp_llvm.pdf?attredirects=0

LLVM bindings for MLKit https://github.com/melsman/sml-llvm

An existing attempt at LLVM bindings for MLton https://smlnj-gforge.cs.uchicago.edu/scm/viewvc.php/trunk/?root=llvm-sml
