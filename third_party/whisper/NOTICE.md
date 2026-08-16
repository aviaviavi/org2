# Bundled local transcription

Org2 Workspace release builds bundle these MIT-licensed components for fully
local, out-of-the-box transcription:

- `whisper.cpp` v1.9.2, commit `306c88f4d1286aec1bf96e544632897886af5501`,
  from <https://github.com/ggml-org/whisper.cpp>.
- The English `base.en` GGML model from
  <https://huggingface.co/ggerganov/whisper.cpp>, with upstream SHA-1
  `137c40403d78fd54d454da0f9bd998f78703390c` and SHA-256
  `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`.

The adjacent license files contain the whisper.cpp and OpenAI Whisper MIT
license texts. Audio and transcripts remain local to the user's selected Org2
corpus.
