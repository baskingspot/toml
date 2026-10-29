const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    const test_step = b.step("test", "Run the unit tests and the toml-test corpus");

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // The corpus tests read `test/toml-test` at run time, so the runner's
    // working directory is the build root.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("test/corpus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "toml", .module = mod }},
    });
    const corpus_tests = b.addTest(.{ .root_module = corpus_mod });
    const run_corpus_tests = b.addRunArtifact(corpus_tests);
    run_corpus_tests.setCwd(b.path("."));
    test_step.dependOn(&run_corpus_tests.step);

    // The guide's examples are real programs against the public module,
    // tested with everything else so a guide page cannot show code that does
    // not build.
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("docs/examples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "toml", .module = mod }},
    });
    const example_tests = b.addTest(.{ .root_module = examples_mod });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    // Fuzzing needs the built-in test runner: the fuzzer speaks a private
    // protocol with the compiler. `just fuzz` drives this step.
    const fuzz_tests = b.addTest(.{ .root_module = mod });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.has_side_effects = true;
    const fuzz_step = b.step("fuzz", "Fuzz the parser (built-in test runner)");
    fuzz_step.dependOn(&run_fuzz_tests.step);
}
