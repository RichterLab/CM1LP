% Animate an x-y contour map from the CDO-converted high-frequency output.
variableName = 'stau';    % mtime, prate, thflux, qvflux, u10, v10, ust, stau,
                        % lwp, cwp, th, qv, qc, u, v, or w
heightMeters = 250;     % Nearest saved height; ignored for surface/path fields
fps = 10;
frameStride = 1;       % Use every Nth output time
nContours = 20;
colorLimits = [];      % []: scan selected frames for fixed limits; or [lo hi]
zUnitsOverride = 'km'; % CM1 GrADS heights are km; CDO omits lev units

scriptDir = fileparts(mfilename('fullpath'));
ncFile = fullfile(scriptDir,'cm1out_hf.nc');
assert(isfile(ncFile),'Place cm1out_hf.nc in this script''s folder.');
assert(nContours >= 2 && nContours == fix(nContours),'nContours must be an integer >= 2.');
assert(fps > 0 && frameStride >= 1 && frameStride == fix(frameStride), ...
    'fps must be positive and frameStride a positive integer.');
info = ncinfo(ncFile,variableName);
dimNames = {info.Dimensions.Name};
dimSizes = [info.Dimensions.Length];
ix = find(ismember(lower(string(dimNames)),["lon","longitude","x","xh"]));
iy = find(ismember(lower(string(dimNames)),["lat","latitude","y","yh"]));
it = find(strcmpi(dimNames,'time'));
assert(isscalar(ix) && isscalar(iy) && isscalar(it), ...
    'Expected x/lon, y/lat, and time dimensions for %s.',variableName);
iz = setdiff(1:numel(dimNames),[ix iy it]);
assert(numel(iz) <= 1,'Expected at most one vertical dimension.');
assert(dimSizes(ix) >= 2 && dimSizes(iy) >= 2, ...
    'contourf requires at least two points in both horizontal directions.');

% CM1 GrADS x/y values are km, despite CDO assigning lon/lat degree units.
x = double(ncread(ncFile,dimNames{ix}));
y = double(ncread(ncFile,dimNames{iy}));
xUnits = 'km';
yUnits = 'km';
units = attributeOr(ncFile,variableName,'units','');
longName = attributeOr(ncFile,variableName,'long_name',variableName);
% CDO retains GrADS units inside long_name rather than a units attribute.
if isempty(units)
    token = regexp(longName,'\s+\(([^()]*)\)\s*$','tokens','once');
    if ~isempty(token)
        units = token{1};
        longName = strtrim(regexprep(longName,'\s+\([^()]*\)\s*$',''));
    end
end
start = ones(1,numel(dimNames));
count = dimSizes;
count(it) = 1;
heightLabel = '';
if ~isempty(iz)
    count(iz) = 1;
    % CDO may retain a singleton surface axis; it is not a height slice.
    if dimSizes(iz) > 1
        z = double(ncread(ncFile,dimNames{iz}));
        zUnits = attributeOr(ncFile,dimNames{iz},'units','');
        if ~isempty(zUnitsOverride)
            zUnits = zUnitsOverride;
        end
        switch lower(strtrim(zUnits))
            case {'km','kilometer','kilometers','kilometre','kilometres'}
                zMeters = 1000*z;
            case {'m','meter','meters','metre','metres'}
                zMeters = z;
            otherwise
                error(['Height units are "%s". Check the original cm1out_hf.ctl ' ...
                    'and set zUnitsOverride to ''km'' or ''m''.'],zUnits);
        end
        [~,start(iz)] = min(abs(zMeters-heightMeters));
        heightLabel = sprintf(' | z = %.1f m',zMeters(start(iz)));
    end
end

% GrADS uses a generic calendar axis. mtime contains actual model seconds.
timeInfo = ncinfo(ncFile,'mtime');
timeDim = find(strcmpi({timeInfo.Dimensions.Name},'time'));
assert(isscalar(timeDim),'mtime must have a time dimension.');
timeStart = ones(1,numel(timeInfo.Dimensions));
timeCount = timeStart;
timeCount(timeDim) = timeInfo.Dimensions(timeDim).Length;
time = double(ncread(ncFile,'mtime',timeStart,timeCount));
time = time(:);
assert(numel(time) == dimSizes(it),'Field and mtime have different time counts.');
frames = unique([1:frameStride:numel(time), numel(time)]);
assert(~isempty(time),'No saved output times.');

% Read one plane at a time, keeping memory use independent of run length.
missingValues = [attributeOr(ncFile,variableName,'_FillValue',[]), ...
    attributeOr(ncFile,variableName,'missing_value',[])];
if isempty(colorLimits)
    lo = Inf;
    hi = -Inf;
    for k = frames
        plane = readPlane(ncFile,variableName,start,count,it,ix,iy,k,missingValues);
        good = plane(isfinite(plane));
        if ~isempty(good)
            lo = min(lo,min(good));
            hi = max(hi,max(good));
        end
    end
    assert(isfinite(lo) && isfinite(hi),'All selected field values are missing.');
    if lo == hi
        pad = max(0.01*abs(lo),1e-12);
        lo = lo-pad;
        hi = hi+pad;
    end
    colorLimits = [lo hi];
end
assert(numel(colorLimits) == 2 && all(isfinite(colorLimits)) && ...
    colorLimits(2) > colorLimits(1),'colorLimits must be increasing [lo hi].');
levels = linspace(colorLimits(1),colorLimits(2),nContours+1);

fig = figure('Color','w','Position',[100 100 850 650]);
ax = axes(fig);
colormap(ax,turbo(256));
for k = frames
    if ~isgraphics(fig)
        break
    end
    plane = readPlane(ncFile,variableName,start,count,it,ix,iy,k,missingValues);
    contourf(ax,x(:),y(:),plane,levels,'LineColor','none');
    clim(ax,colorLimits);
    axis(ax,'equal');
    axis(ax,'tight');
    xlabel(ax,sprintf('x (%s)',xUnits),'Interpreter','none');
    ylabel(ax,sprintf('y (%s)',yUnits),'Interpreter','none');
    cb = colorbar(ax);
    cb.Label.String = sprintf('%s (%s)',variableName,units);
    cb.Label.Interpreter = 'none';
    title(ax,sprintf('%s%s | Model time %.2f min', ...
        longName,heightLabel,time(k)/60),'Interpreter','none');
    drawnow;
    pause(1/fps);
end

function plane = readPlane(file,name,start,count,it,ix,iy,k,missingValues)
    start(it) = k;
    values = double(ncread(file,name,start,count));
    % Explicit dimensions avoid squeeze/transposition ambiguity for CDO files.
    values = reshape(values,count);
    order = [iy ix setdiff(1:numel(count),[iy ix],'stable')];
    values = permute(values,order);
    plane = reshape(values,count(iy),count(ix));
    for missing = missingValues(:)'
        plane(plane == missing) = NaN;
    end
    plane(~isfinite(plane) | abs(plane) > 1e35) = NaN;
end

function value = attributeOr(file,name,attribute,fallback)
    info = ncinfo(file,name);
    index = find(strcmp({info.Attributes.Name},attribute),1);
    if isempty(index)
        value = fallback;
    else
        value = info.Attributes(index).Value;
    end
end
