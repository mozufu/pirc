/** Compile the App's real API client (apps/android .../dev/pirc/android/core of a
 * given checkout) with the harness scripts/e2e/jvm/AppCompat.kt, using only the
 * Kotlin compiler, libraries and Android platform jar already in the local
 * Gradle cache and SDK (the recipe of scripts/prepare-native-first-send.py).
 * Nothing is downloaded and no Android source is modified. The result is cached
 * by a hash of the sources under target/suites/e2e-jvm/. */
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { repoRoot } from './lib.mjs';

const cache = path.join(os.homedir(), '.gradle/caches/modules-2/files-2.1');
function jar(group, artifact, version) {
  const base = path.join(cache, group, artifact, version);
  const found = fs.existsSync(base)
    ? fs.readdirSync(base).flatMap((hash) =>
        fs
          .readdirSync(path.join(base, hash))
          .filter((f) => f.endsWith('.jar') && !f.endsWith('-sources.jar'))
          .map((f) => path.join(base, hash, f)),
      )
    : [];
  if (found.length < 1)
    throw new Error(
      `missing cached ${group}:${artifact}:${version}; run Android dependency resolution first`,
    );
  return found[0];
}
const sources = (dir) => {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...sources(full));
    else if (entry.name.endsWith('.kt')) out.push(full);
  }
  return out.sort();
};

/** Returns { java, classpath, key }. `tree` is a checkout root. */
export function buildAppClient(tree, label) {
  const main = path.join(tree, 'apps/android/android/app/src/main/kotlin');
  const kotlin = (artifact) => jar('org.jetbrains.kotlin', artifact, '2.3.20');
  const files = [
    ...sources(path.join(main, 'dev/pirc/android/core')),
    path.join(main, 'dev/pirc/android/BuildConfig.kt'),
    path.join(repoRoot, 'scripts/e2e/jvm/AppCompat.kt'),
  ];
  const hash = createHash('sha256');
  for (const file of files)
    hash.update(file.replace(tree, '') + '\0').update(fs.readFileSync(file));
  const key = hash.digest('hex').slice(0, 16);
  const out = path.join(repoRoot, 'target/suites/e2e-jvm', `${label}-${key}`);
  const compilerPath = [
    'kotlin-compiler-embeddable',
    'kotlin-stdlib',
    'kotlin-script-runtime',
    'kotlin-daemon-embeddable',
  ].map(kotlin);
  compilerPath.push(
    jar('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
    jar('org.jetbrains', 'annotations', '23.0.0'),
    jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
  );
  const cp = [kotlin('kotlin-stdlib'), jar('org.jetbrains', 'annotations', '23.0.0')];
  for (const [artifact, version] of [
    ['kotlinx-coroutines-core-jvm', '1.10.2'],
    ['kotlinx-serialization-core-jvm', '1.9.0'],
    ['kotlinx-serialization-json-jvm', '1.9.0'],
  ])
    cp.push(jar('org.jetbrains.kotlinx', artifact, version));
  for (const [group, artifact, version] of [
    ['com.squareup.okhttp3', 'okhttp-jvm', '5.1.0'],
    ['com.squareup.okio', 'okio-jvm', '3.15.0'],
  ])
    cp.push(jar(group, artifact, version));
  const sdk = process.env.ANDROID_HOME || path.join(os.homedir(), 'Library/Android/sdk');
  const androidJar = path.join(sdk, 'platforms/android-36/android.jar');
  if (!fs.existsSync(androidJar)) throw new Error('Android platform 36 jar not found');
  cp.push(androidJar);
  const java = execFileSync('which', ['java'], { encoding: 'utf8' }).trim();
  const classes = path.join(out, 'classes');
  if (!fs.existsSync(path.join(out, 'done'))) {
    fs.rmSync(out, { recursive: true, force: true });
    fs.mkdirSync(classes, { recursive: true });
    // The App's generated build-time constants (debug build, as the JVM tests use).
    const generated = path.join(out, 'BuildConfig.kt');
    fs.writeFileSync(
      generated,
      'package dev.pirc.pirc_mobile\nobject BuildConfig { const val DEBUG = true }\n',
    );
    files.push(generated);
    const result = spawnSync(
      java,
      [
        '-Xmx1536m',
        '-cp',
        compilerPath.join(path.delimiter),
        'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
        '-no-stdlib',
        '-no-reflect',
        '-jvm-target',
        '17',
        '-nowarn',
        '-Xplugin=' + kotlin('kotlin-serialization-compiler-plugin-embeddable'),
        '-classpath',
        cp.join(path.delimiter),
        '-d',
        classes,
        ...files,
      ],
      { encoding: 'utf8' },
    );
    if (result.status !== 0)
      throw new Error(
        `compiling the ${label} App client failed:\n${(result.stdout + result.stderr).slice(-3000)}`,
      );
    fs.writeFileSync(path.join(out, 'done'), key);
  }
  return { java, classpath: [classes, ...cp].join(path.delimiter), key };
}

/** Run the harness; returns the parsed OP lines. */
export function runAppClient(client, args) {
  const result = spawnSync(
    client.java,
    ['-cp', client.classpath, 'dev.pirc.e2e.AppCompat', ...args],
    { encoding: 'utf8', timeout: 120000 },
  );
  if (result.status !== 0)
    throw new Error(
      'the App client harness failed:\n' + (result.stdout + result.stderr).slice(-2000),
    );
  return result.stdout
    .split('\n')
    .filter((l) => l.startsWith('OP|'))
    .map((line) => {
      const [, name, outcome, status, code, ...message] = line.split('|');
      return {
        name,
        ok: outcome === 'OK',
        status: status && status !== '-' ? Number(status) : undefined,
        code,
        message: message.join('|'),
      };
    });
}
