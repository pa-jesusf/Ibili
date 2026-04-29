#ifndef FFmpegRemux_h
#define FFmpegRemux_h

#ifdef __cplusplus
extern "C" {
#endif

int ibili_remux_mp4(const char *video_path,
                    const char *audio_path,
                    const char *output_path,
                    char *error_buffer,
                    int error_buffer_size);

int ibili_remux_hls(const char *video_path,
                    const char *audio_path,
                    const char *playlist_path,
                    const char *init_filename,
                    const char *segment_filename,
                    char *error_buffer,
                    int error_buffer_size);

int ibili_remux_hls_live(const char *video_path,
                         const char *audio_path,
                         const char *playlist_path,
                         const char *init_filename,
                         const char *segment_filename,
                         int hls_time,
                         char *error_buffer,
                         int error_buffer_size);

int ibili_remux_fmp4(const char *video_path,
                     const char *audio_path,
                     const char *output_path,
                     char *error_buffer,
                     int error_buffer_size);

#ifdef __cplusplus
}
#endif

#endif
