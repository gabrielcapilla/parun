## Source index facade.
##
## Single import surface for schema + codec + builder + validator + runtime reader.

import
  source_index_core, source_index_codec, source_index_builder, source_index_validation,
  source_index_runtime

export source_index_core
export source_index_codec
export source_index_builder
export source_index_validation
export source_index_runtime
