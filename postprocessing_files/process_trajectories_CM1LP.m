function trajectories = process_trajectories_CM1LP(input_directory,output_filename)
%PROCESS_TRAJECTORIES_CM1LP Stitch binary CM1LP particle trajectories.
%
% Each MPI rank writes one binary file containing 15 single-precision
% values per particle record. Particles can migrate between MPI ranks, so
% records are stitched together using the pair (procidx, pidx).
% Each element of trajectories contains named, variable-length vectors for
% one particle, ordered by mtime. Field names follow the corresponding
% pdata indices in droplet.F with the "pr" prefix removed.
%
% trajectories = process_trajectories_CM1LP(input_directory)
% reads rank files directly from input_directory and writes trajectories.mat
% to that directory.
%
% trajectories = process_trajectories_CM1LP(input_directory,output_filename)
% writes the processed structure array to the specified file.
%
% Examples:
%   trajectories = process_trajectories_CM1LP( ...
%       '/scratch/username/case01/particle_traj');
%   trajectories = process_trajectories_CM1LP( ...
%       '/scratch/username/case02/particle_traj', ...
%       '/scratch/username/case02/trajectories.mat');

if nargin<1 || isempty(input_directory)
    error('input_directory is required and must contain the MPI-rank .dat files.');
end

input_directory = char(input_directory);
if ~isfolder(input_directory)
    error('Input directory does not exist: %s',input_directory);
end

if nargin<2 || isempty(output_filename)
    output_filename = fullfile(input_directory,'trajectories.mat');
else
    output_filename = char(output_filename);
end

output_directory = fileparts(output_filename);
if ~isempty(output_directory) && ~isfolder(output_directory)
    error('Output directory does not exist: %s',output_directory);
end

machine_format = 'n';  % Native byte order, matching the CM1LP run platform.

num_variables = 15;
bytes_per_value = 4;
entry_size_in_bytes = bytes_per_value*num_variables;

%% Discover and validate the per-rank files

rank_files = dir(fullfile(input_directory,'*.dat'));
is_rank_file = ~[rank_files.isdir] & ...
    ~cellfun(@isempty,regexp({rank_files.name},'^\d+\.dat$','once'));
rank_files = rank_files(is_rank_file);

if isempty(rank_files)
    error('No MPI-rank trajectory files were found in %s.',input_directory);
end

[~,file_order] = sort({rank_files.name});
rank_files = rank_files(file_order);

file_sizes = [rank_files.bytes];
if any(mod(file_sizes,entry_size_in_bytes)~=0)
    bad_file = find(mod(file_sizes,entry_size_in_bytes)~=0,1);
    error('Unexpected size for %s. Check num_variables and binary precision.', ...
        fullfile(input_directory,rank_files(bad_file).name));
end

entries_per_file = file_sizes/entry_size_in_bytes;
total_entries = sum(entries_per_file);

if total_entries==0
    error('The MPI-rank trajectory files contain no records.');
end

%% Read all records into one preallocated single-precision array

records = zeros(total_entries,num_variables,'single');
next_row = 1;

for file_index = 1:numel(rank_files)
    num_entries = entries_per_file(file_index);
    if num_entries==0
        continue
    end

    filename = fullfile(input_directory,rank_files(file_index).name);
    file_id = fopen(filename,'rb',machine_format);
    if file_id<0
        error('Could not open trajectory file %s.',filename);
    end

    file_records = fread(file_id,[num_variables,num_entries],'single=>single');
    close_status = fclose(file_id);
    if close_status~=0
        error('Could not close trajectory file %s.',filename);
    end
    if numel(file_records)~=num_variables*num_entries
        error('Could not read all expected trajectory records from %s.',filename);
    end

    rows = next_row:next_row+num_entries-1;
    records(rows,:) = file_records.';
    next_row = next_row+num_entries;
end

%% Stitch particles across ranks and sort every trajectory by model time

% Sorting by both identity columns avoids imposing an arbitrary maximum
% particle ID when constructing a globally unique identity.
records = sortrows(records,[2 1 3]);

identity_changed = records(2:end,1)~=records(1:end-1,1) | ...
                   records(2:end,2)~=records(1:end-1,2);
trajectory_start = [1; find(identity_changed)+1];
trajectory_stop = [trajectory_start(2:end)-1; total_entries];
num_trajectories = numel(trajectory_start);

trajectory_template = struct( ...
    'pidx',single([]), ...
    'procidx',single([]), ...
    'mtime',single([]), ...
    'x',single([]), ...
    'y',single([]), ...
    'z',single([]), ...
    'vpx',single([]), ...
    'vpy',single([]), ...
    'vpz',single([]), ...
    'rp',single([]), ...
    'tp',single([]), ...
    'ms',single([]), ...
    'mult',single([]), ...
    't',single([]), ...
    'qv',single([]));
trajectories(num_trajectories,1) = trajectory_template;

for trajectory_index = 1:num_trajectories
    rows = trajectory_start(trajectory_index):trajectory_stop(trajectory_index);

    trajectories(trajectory_index).pidx = records(rows(1),1);
    trajectories(trajectory_index).procidx = records(rows(1),2);
    trajectories(trajectory_index).mtime = records(rows,3);
    trajectories(trajectory_index).x = records(rows,4);
    trajectories(trajectory_index).y = records(rows,5);
    trajectories(trajectory_index).z = records(rows,6);
    trajectories(trajectory_index).vpx = records(rows,7);
    trajectories(trajectory_index).vpy = records(rows,8);
    trajectories(trajectory_index).vpz = records(rows,9);
    trajectories(trajectory_index).rp = records(rows,10);
    trajectories(trajectory_index).tp = records(rows,11);
    trajectories(trajectory_index).ms = records(rows,12);
    trajectories(trajectory_index).mult = records(rows,13);
    trajectories(trajectory_index).t = records(rows,14);
    trajectories(trajectory_index).qv = records(rows,15);
end

fprintf('Processed %d records into %d trajectories.\n', ...
    total_entries,num_trajectories);

save(output_filename,'trajectories','-v7.3');

end
