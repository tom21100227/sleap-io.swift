// HDF5VideoBackend
//
// The HDF5 video backend (for embedded frames in .slp files) lives in the
// SleapHDF5 module, not here. SleapVideo cannot depend on SleapHDF5.
//
// To use HDF5 embedded video, the SleapHDF5 module creates a backend
// conforming to VideoBackend and assigns it to `video.backend` directly:
//
//     let backend = SleapHDF5EmbeddedVideoBackend(file: hdf5File, videoIndex: 0)
//     video.backend = backend
//
// This keeps the dependency graph clean:
//     SleapVideo --> SleapIO
//     SleapHDF5  --> SleapIO (+ CHDF5)
//
// There is no dependency between SleapVideo and SleapHDF5.
