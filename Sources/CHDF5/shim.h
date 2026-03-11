#ifndef CHDF5_SHIM_H
#define CHDF5_SHIM_H

#include <hdf5.h>

// HDF5 "constants" are actually macros that expand to (H5OPEN expr_g) where
// H5OPEN triggers library initialization. Swift cannot import these macros,
// so we expose them as static inline C functions.

// --- Native types ---
static inline hid_t shim_H5T_NATIVE_INT8(void)    { return H5T_NATIVE_INT8; }
static inline hid_t shim_H5T_NATIVE_INT16(void)   { return H5T_NATIVE_INT16; }
static inline hid_t shim_H5T_NATIVE_INT32(void)   { return H5T_NATIVE_INT32; }
static inline hid_t shim_H5T_NATIVE_INT64(void)   { return H5T_NATIVE_INT64; }
static inline hid_t shim_H5T_NATIVE_UINT8(void)   { return H5T_NATIVE_UINT8; }
static inline hid_t shim_H5T_NATIVE_UINT16(void)  { return H5T_NATIVE_UINT16; }
static inline hid_t shim_H5T_NATIVE_UINT32(void)  { return H5T_NATIVE_UINT32; }
static inline hid_t shim_H5T_NATIVE_UINT64(void)  { return H5T_NATIVE_UINT64; }
static inline hid_t shim_H5T_NATIVE_FLOAT(void)   { return H5T_NATIVE_FLOAT; }
static inline hid_t shim_H5T_NATIVE_DOUBLE(void)  { return H5T_NATIVE_DOUBLE; }
static inline hid_t shim_H5T_NATIVE_HBOOL(void)   { return H5T_NATIVE_HBOOL; }

// --- String types ---
static inline hid_t shim_H5T_C_S1(void)           { return H5T_C_S1; }

// --- Variable-length size sentinel ---
static inline size_t shim_H5T_VARIABLE(void)       { return H5T_VARIABLE; }

// --- Standard types (for compound field matching) ---
static inline hid_t shim_H5T_STD_U8LE(void)       { return H5T_STD_U8LE; }
static inline hid_t shim_H5T_STD_I8LE(void)        { return H5T_STD_I8LE; }
static inline hid_t shim_H5T_IEEE_F32LE(void)     { return H5T_IEEE_F32LE; }
static inline hid_t shim_H5T_IEEE_F64LE(void)     { return H5T_IEEE_F64LE; }

// --- Compound type class ---
static inline H5T_class_t shim_H5T_COMPOUND(void) { return H5T_COMPOUND; }
static inline H5T_class_t shim_H5T_STRING(void)   { return H5T_STRING; }
static inline H5T_class_t shim_H5T_VLEN(void)     { return H5T_VLEN; }
static inline H5T_class_t shim_H5T_INTEGER(void)  { return H5T_INTEGER; }
static inline H5T_class_t shim_H5T_FLOAT(void)    { return H5T_FLOAT; }

// --- Constants that Swift imports as wrong type (Int32 vs hid_t/Int64) ---
// H5P_DEFAULT and H5S_ALL are simple #defines but Swift may import them
// as Int32 while hid_t is Int64 in HDF5 2.x.
static inline hid_t shim_H5P_DEFAULT(void)             { return (hid_t)H5P_DEFAULT; }
static inline hid_t shim_H5S_ALL(void)                 { return (hid_t)H5S_ALL; }

// --- Property list class IDs (use H5OPEN macro, not importable) ---
static inline hid_t shim_H5P_DATASET_CREATE(void)      { return H5P_DATASET_CREATE; }
static inline hid_t shim_H5P_DATASET_ACCESS(void)      { return H5P_DATASET_ACCESS; }

// --- File access flags (simple constants but ensure correct type) ---
static inline unsigned shim_H5F_ACC_RDONLY(void)        { return H5F_ACC_RDONLY; }
static inline unsigned shim_H5F_ACC_RDWR(void)          { return H5F_ACC_RDWR; }
static inline unsigned shim_H5F_ACC_TRUNC(void)         { return H5F_ACC_TRUNC; }

#endif /* CHDF5_SHIM_H */
