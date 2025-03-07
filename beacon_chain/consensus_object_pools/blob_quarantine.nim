# beacon_chain
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import ../spec/helpers
from std/sequtils import mapIt
from std/strutils import join

const
  MaxBlobs = SLOTS_PER_EPOCH * MAX_BLOBS_PER_BLOCK

type
  BlobQuarantine* = object
    blobs*: OrderedTable[(Eth2Digest, BlobIndex), ref BlobSidecar]
  BlobFetchRecord* = object
    block_root*: Eth2Digest
    indices*: seq[BlobIndex]

func shortLog*(x: seq[BlobIndex]): string =
  "<" & x.mapIt($it).join(", ") & ">"

func shortLog*(x: seq[BlobFetchRecord]): string =
  "[" & x.mapIt(shortLog(it.block_root) & shortLog(it.indices)).join(", ") & "]"

func put*(quarantine: var BlobQuarantine, blobSidecar: ref BlobSidecar) =
  if quarantine.blobs.lenu64 > MaxBlobs:
    # FIFO if full. For example, sync manager and request manager can race to
    # put blobs in at the same time, so one gets blob insert -> block resolve
    # -> blob insert sequence, which leaves garbage blobs.
    var oldest_blob_key: (Eth2Digest, BlobIndex)
    for k in quarantine.blobs.keys:
      oldest_blob_key = k
      break
    quarantine.blobs.del oldest_blob_key
  let block_root = hash_tree_root(blobSidecar.signed_block_header.message)
  discard quarantine.blobs.hasKeyOrPut(
    (block_root, blobSidecar.index), blobSidecar)

func blobIndices*(quarantine: BlobQuarantine, digest: Eth2Digest):
     seq[BlobIndex] =
  var r: seq[BlobIndex] = @[]
  for i in 0..<MAX_BLOBS_PER_BLOCK:
    if quarantine.blobs.hasKey((digest, i)):
      r.add(i)
  r

func hasBlob*(
    quarantine: BlobQuarantine,
    slot: Slot,
    proposer_index: uint64,
    index: BlobIndex): bool =
  for blob_sidecar in quarantine.blobs.values:
    template block_header: untyped = blob_sidecar.signed_block_header.message
    if block_header.slot == slot and
        block_header.proposer_index == proposer_index and
        blob_sidecar.index == index:
      return true
  false

func popBlobs*(quarantine: var BlobQuarantine, digest: Eth2Digest):
     seq[ref BlobSidecar] =
  var r: seq[ref BlobSidecar] = @[]
  for i in 0..<MAX_BLOBS_PER_BLOCK:
    var b: ref BlobSidecar
    if quarantine.blobs.pop((digest, i), b):
      r.add(b)
  r

func hasBlobs*(quarantine: BlobQuarantine, blck: deneb.SignedBeaconBlock):
     bool =
  let idxs = quarantine.blobIndices(blck.root)
  if len(blck.message.body.blob_kzg_commitments) != len(idxs):
    return false
  for i in 0..<len(idxs):
    if idxs[i] != uint64(i):
      return false
  true

func blobFetchRecord*(quarantine: BlobQuarantine, blck: deneb.SignedBeaconBlock):
     BlobFetchRecord =
  var indices: seq[BlobIndex]
  for i in 0..<len(blck.message.body.blob_kzg_commitments):
    let idx = BlobIndex(i)
    if not quarantine.blobs.hasKey((blck.root, idx)):
      indices.add(idx)
  BlobFetchRecord(block_root: blck.root, indices: indices)
