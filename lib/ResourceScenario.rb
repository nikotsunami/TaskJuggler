#!/usr/bin/env ruby -w
# encoding: UTF-8
#
# = ResourceScenario.rb -- The TaskJuggler III Project Management Software
#
# Copyright (c) 2006, 2007, 2008, 2009 by Chris Schlaeger <cs@kde.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#


require 'ScenarioData'

class TaskJuggler

  class ResourceScenario < ScenarioData

    def initialize(resource, scenarioIdx, attributes)
      super

      # The scoreboard entries are either nil, a number or a task reference. nil
      # means the slot is unassigned. The task reference means assigned to this
      # task. The numbers have the following values:
      # 1: Off hour
      # 2: Vacation
      # The scoreboard is only created when needed to save memory for projects
      # which read-in the coporate employee database but only need a small
      # subset.
      @scoreboard = nil

      @firstBookedSlot = nil
      @lastBookedSlot = nil
    end

    # This method must be called at the beginning of each scheduling run. It
    # initializes variables used during the scheduling process.
    def prepareScheduling
      @property['effort', @scenarioIdx] = 0
      initScoreboard
    end

    # The criticalness of a resource is a measure for the probabilty that all
    # allocations can be fullfilled. The smaller the value, the more likely
    # will the tasks get the resource. A value above 1.0 means that
    # statistically some tasks will not get their resources. A value between
    # 0 and 1 implies no guarantee, though.
    def calcCriticalness
      if @scoreboard.nil?
        # Resources that are not allocated are not critical at all.
        @property['criticalness', @scenarioIdx] = 0.0
      else
        freeSlots = 0
        @scoreboard.each do |slot|
          freeSlots += 1 if slot.nil?
        end
        @property['criticalness', @scenarioIdx] = freeSlots == 0 ? 1.0 :
          a('alloctdeffort') / freeSlots
      end
    end

    # Returns true if the resource is available at the time specified by
    # _sbIdx_.
    def available?(sbIdx)
      return false unless @scoreboard[sbIdx].nil?

      limits = a('limits')
      return false if limits && !limits.ok?(@scoreboard.idxToDate(sbIdx))

      true
    end

    # Return true if the resource is booked for a tasks at the time specified by
    # _sbIdx_.
    def booked?(sbIdx)
      @scoreboard[sbIdx].is_a?(Task)
    end

    # Book the slot indicated by the scoreboard index +sbIdx+ for Task +task+.
    # If +force+ is true, overwrite the existing booking for this slot. The
    # method returns true if the slot was available.
    def book(sbIdx, task, force = false)
      return false if !force && !available?(sbIdx)

      #puts "Booking resource #{@property.fullId} at " +
      #     "#{@scoreboard.idxToDate(sbIdx)}/#{sbIdx} for task #{task.fullId}\n"
      @scoreboard[sbIdx] = task
      # Track the total allocated slots for this resource and all parent
      # resources.
      t = @property
      while t
        t['effort', @scenarioIdx] += 1
        t = t.parent
      end
      a('limits').inc(@scoreboard.idxToDate(sbIdx)) if a('limits')

      # Make sure the task is in the list of duties.
      @property['duties', @scenarioIdx] << task unless a('duties').include?(task)

      if @firstBookedSlot.nil? || @firstBookedSlot > sbIdx
        @firstBookedSlot = sbIdx
      end
      if @lastBookedSlot.nil? || @lastBookedSlot < sbIdx
        @lastBookedSlot = sbIdx
      end
      true
    end

    def bookBooking(sbIdx, booking)
      initScoreboard if @scoreboard.nil?

      unless @scoreboard[sbIdx].nil?
        if booked?(sbIdx)
          error('booking_conflict',
                "Resource #{@property.fullId} has multiple conflicting " +
                "bookings for #{@scoreboard.idxToDate(sbIdx)}. The " +
                "conflicting tasks are #{@scoreboard[sbIdx].fullId} and " +
                "#{booking.task.fullId}.", true, booking.sourceFileInfo)
        end
        if @scoreboard[sbIdx] > booking.overtime
          if @scoreboard[sbIdx] == 1 && booking.sloppy == 0
            error('booking_no_duty',
                  "Resource #{@property.fullId} has no duty at " +
                  "#{@scoreboard.idxToDate(sbIdx)}.", true,
                  booking.sourceFileInfo)
          end
          if @scoreboard[sbIdx] == 2 && booking.sloppy <= 1
            error('booking_on_vacation',
                  "Resource #{@property.fullId} is on vacation at " +
                  "#{@scoreboard.idxToDate(sbIdx)}.", true,
                  booking.sourceFileInfo)
          end
          return false
        end
      end

      book(sbIdx, booking.task, true)
    end

    def query_alert(query)
      journal = @project['journal']
      endDate = query.end
      query.sortableResult = journal.alertLevel(endDate, @property)
      query.result = @project['alertLevels'][query.sortableResult][0]
    end

    # Compute the cost generated by this Resource for a given Account during a
    # given interval.  If a Task is provided as scopeProperty only the turnover
    # directly assiciated with the Task is taken into account.
    def query_cost(query)
      if query.costAccount
        query.sortableResult = query.numericalResult =
          turnover(query.startIdx, query.endIdx, query.costAccount,
                   query.scopeProperty)
        query.result = query.currencyFormat.format(query.sortableResult)
      else
        query.result = 'No cost account'
      end
    end

    # The effort allocated to the Resource in the specified interval. In case a
    # Task is given as scope property only the effort allocated to this Task is
    # taken into account.
    def query_effort(query)
      query.sortableResult = query.numericalResult =
        getEffectiveWork(query.startIdx, query.endIdx, query.scopeProperty)
      query.result = query.scaleLoad(query.sortableResult)
    end

    # The unallocated work time of the Resource during the specified interval.
    def query_freetime(query)
      query.sortableResult = query.numericalResult =
        getEffectiveFreeTime(query.startIdx, query.endIdx) / (60 * 60 * 24)
      query.result = query.scaleDuration(query.sortableResult)
    end

    # The unallocated effort of the Resource during the specified interval.
    def query_freework(query)
      query.sortableResult = query.numericalResult =
        getEffectiveFreeWork(query.startIdx, query.endIdx)
      query.result = query.scaleLoad(query.sortableResult)
    end

    # Get the rate of the resource.
    def query_rate(query)
      query.sortableResult = query.numericalResult = rate
      query.result = query.currencyFormat.format(query.sortableResult)
    end

    # Compute the revenue generated by this Resource for a given Account during
    # a given interval.  If a Task is provided as scopeProperty only the
    # revenue directly associated to this Task is taken into account.
    def query_revenue(query)
      if query.revenueAccount
        query.sortableResult = query.numericalResult =
          turnover(query.startIdx, query.endIdx, query.revenueAccount,
                   query.scopeProperty)
        query.result = query.currencyFormat.format(query.sortableResult)
      else
        query.result = 'No revenue account'
      end
    end

    # Returns the work of the resource (and its children) weighted by their
    # efficiency.
    def getEffectiveWork(startIdx, endIdx, task = nil)
      # Convert the interval dates to indexes if needed.
      startIdx = @project.dateToIdx(startIdx, true) if startIdx.is_a?(TjTime)
      endIdx = @project.dateToIdx(endIdx, true) if endIdx.is_a?(TjTime)

      work = 0.0
      if @property.container?
        @property.children.each do |resource|
          work += resource.getEffectiveWork(@scenarioIdx, startIdx, endIdx, task)
        end
      else
        return 0.0 if @scoreboard.nil?

        work = @project.convertToDailyLoad(
                 getAllocatedSlots(startIdx, endIdx, task) *
                 @project['scheduleGranularity']) * a('efficiency')
      end
      work
    end

    # Returns the allocated work of the resource (and its children).
    def getAllocatedWork(startIdx, endIdx, task = nil)
      # Convert the interval dates to indexes if needed.
      startIdx = @project.dateToIdx(startIdx, true) if startIdx.is_a?(TjTime)
      endIdx = @project.dateToIdx(endIdx, true) if endIdx.is_a?(TjTime)

      work = 0.0
      if @property.container?
        @property.children.each do |resource|
          work += resource.getAllocatedWork(@scenarioIdx, startIdx, endIdx, task)
        end
      else
        return 0.0 if @scoreboard.nil?

        work = @project.convertToDailyLoad(
                 getAllocatedSlots(startIdx, endIdx, task) *
                 @project['scheduleGranularity'])
      end
      work
    end

    # Returns the allocated accumulated time of this resource and its children.
    def getAllocatedTime(startIdx, endIdx, task = nil)
      # Convert the interval dates to indexes if needed.
      startIdx = @project.dateToIdx(startIdx, true) if startIdx.is_a?(TjTime)
      endIdx = @project.dateToIdx(endIdx, true) if endIdx.is_a?(TjTime)

      time = 0
      if @property.container?
        @property.children.each do |resource|
          time += resource.getAllocatedWork(@scenarioIdx, startIdx, endIdx, task)
        end
      else
        return 0 if @scoreboard.nil?

        time = @project.convertToDailyLoad(@project['scheduleGranularity'] *
            getAllocatedSlots(startIdx, endIdx, task))
      end
      time
    end

    # Return the unallocated work time (in seconds) of the resource and its
    # children.
    def getEffectiveFreeTime(startIdx, endIdx)
      # Convert the interval dates to indexes if needed.
      startIdx = @project.dateToIdx(startIdx, true) if startIdx.is_a?(TjTime)
      endIdx = @project.dateToIdx(endIdx, true) if endIdx.is_a?(TjTime)

      freeTime = 0
      if @property.container?
        @property.children.each do |resource|
          freeTime += resource.getEffectiveFreeTime(@scenarioIdx, startIdx,
                                                    endIdx)
        end
      else
        initScoreboard if @scoreboard.nil?

        freeTime = getFreeSlots(startIdx, endIdx) *
          @project['scheduleGranularity']
      end
      freeTime
    end

    # Return the unallocated work of the resource and its children weighted by
    # their efficiency.
    def getEffectiveFreeWork(startIdx, endIdx)
      # Convert the interval dates to indexes if needed.
      startIdx = @project.dateToIdx(startIdx, true) if startIdx.is_a?(TjTime)
      endIdx = @project.dateToIdx(endIdx, true) if endIdx.is_a?(TjTime)

      work = 0.0
      if @property.container?
        @property.children.each do |resource|
          work += resource.getEffectiveFreeWork(@scenarioIdx, startIdx, endIdx)
        end
      else
        initScoreboard if @scoreboard.nil?

        work = @project.convertToDailyLoad(
                 getFreeSlots(startIdx, endIdx) *
                 @project['scheduleGranularity']) * a('efficiency')
      end
      work
    end

    def turnover(startIdx, endIdx, account, task = nil)
      amount = 0.0
      if @property.container?
        @property.children.each do |child|
          amount += child.turnover(@scenarioIdx, startIdx, endIdx, account, task)
        end
      else
        a('duties').each do |duty|
          amount += duty.turnover(@scenarioIdx, startIdx, endIdx, account,
                                  @property)
        end
      end

      amount
    end

    # Returns the cost for using this resource during the specified Interval
    # _period_. If a Task _task_ is provided, only the work on this particular
    # task is considered.
    def cost(startIdx, endIdx, task = nil)
      getAllocatedTime(startIdx, endIdx, task) * a('rate')
    end

    # Returns true if the resource or any of its children is allocated during
    # the period specified with the Interval _iv_. If task is not nil
    # only allocations to this tasks are respected.
    def allocated?(iv, task = nil)
      initScoreboard if @scoreboard.nil?

      startIdx = @scoreboard.dateToIdx(iv.start, true)
      endIdx = @scoreboard.dateToIdx(iv.end, true)

      startIdx = @firstBookedSlot if @firstBookedSlot &&
                                     startIdx < @firstBookedSlot
      endIdx = @lastBookedSlot + 1 if @lastBookedSlot &&
                                      endIdx < @lastBookedSlot + 1
      return false if startIdx > endIdx

      return allocatedSub(startIdx, endIdx, task)
    end

    # Iterate over the scoreboard and turn its content into a set of Bookings.
    def getBookings
      return {} if @property.container? || @scoreboard.nil? ||
                   @firstBookedSlot.nil? || @lastBookedSlot.nil?

      bookings = {}
      lastTask = nil
      bookingStart = nil

      # To speedup the collection we start with the first booked slot and end
      # with the last booked slot.
      startIdx = @firstBookedSlot
      endIdx = @lastBookedSlot + 1

      # In case the index markers are still uninitialized, we have no bookings.
      return {} if startIdx.nil? || endIdx.nil?

      startIdx.upto(endIdx) do |idx|
        task = @scoreboard[idx]
        # Now we watch for task changes.
        if task != lastTask || (lastTask == nil && task.is_a?(Task)) ||
           (task.is_a?(Task) && idx == endIdx)
          unless lastTask.nil?
            # If we don't have a Booking for the task yet, we create one.
            if bookings[lastTask].nil?
              bookings[lastTask] = Booking.new(@property, lastTask, [])
            end

            # Make sure the index is correct even for the last task block.
            idx += 1 if idx == endIdx
            # Append the new interval to the Booking.
            bookings[lastTask].intervals <<
              Interval.new(@scoreboard.idxToDate(bookingStart),
                           @scoreboard.idxToDate(idx))
          end
          # Get ready for the next task booking interval
          if task.is_a?(Task)
            lastTask = task
            bookingStart = idx
          else
            lastTask = bookingStart = nil
          end
        end
      end
      bookings
    end

    # Return a list of scoreboard intervals that are at least _minDuration_ long
    # and contain only 1 and 2. These values determine off-hours of the
    # resource. The result is an Array of [ start, end ] TjTime values.
    def collectTimeOffIntervals(iv, minDuration)
      initScoreboard if @scoreboard.nil?

      @scoreboard.collectTimeOffIntervals(iv, minDuration, [ 1, 2 ])
    end

  private

    def initScoreboard
      # Create scoreboard and mark all slots as unavailable
      @scoreboard = Scoreboard.new(@project['start'], @project['end'],
                                   @project['scheduleGranularity'], 1)

      # We'll need this frequently and can savely cache it here.
      @shifts = a('shifts')
      @workinghours = a('workinghours')

      # Change all work time slots to nil (available) again.
      date = @scoreboard.idxToDate(0)
      delta = @project['scheduleGranularity']
      @project.scoreboardSize.times do |i|
        @scoreboard[i] = nil if onShift?(date)
        date += delta
      end

      # Mark all resource specific vacation slots as such (2)
      a('vacations').each do |vacation|
        startIdx = @scoreboard.dateToIdx(vacation.start, true)
        endIdx = @scoreboard.dateToIdx(vacation.end, true)
        startIdx.upto(endIdx - 1) do |i|
           @scoreboard[i] = 2
        end
      end

      # Mark all global vacation slots as such (2)
      @project['vacations'].each do |vacation|
        startIdx = @scoreboard.dateToIdx(vacation.start, true)
        endIdx = @scoreboard.dateToIdx(vacation.end, true)
        startIdx.upto(endIdx - 1) do |i|
           @scoreboard[i] = 2
        end
      end

      unless @shifts.nil?
        # Mark the vacations from all the shifts the resource is assigned to.
        @project.scoreboardSize.times do |i|
          v = @shifts.getSbSlot(@scoreboard.idxToDate(i))
          # Check if the vacation replacement bit is set. In that case we copy
          # the while interval over to the resource scoreboard overriding any
          # global vacations.
          if (v & (1 << 8)) > 0
            # The ShiftAssignments scoreboard and the ResourceScenario scoreboard
            # unfortunately can't use the same values for a certain meaning. So,
            # we have to use a map to translate the values.
            map = [ nil, nil, 1, 2 ]
            @scoreboard[i] = map[v & 0xFF]
          elsif (v & 0xFF) == 3
            # 3 in ShiftAssignments means 2 in ResourceScenario (on vacation)
            @scoreboard[i] = 2
          end
        end
      end
    end

    def onShift?(date)
      # The more redable but slower form would be:
      # if @shifts.assigned?(date)
      #   return @shifts.onShift?(date)
      # else
      #   @workinghours.onShift?(date)
      # end
      if @shifts && (v = (@shifts.getSbSlot(date) & 0xFF)) > 0
        v == 1
      else
        @workinghours.onShift?(date)
      end
    end

    # Count the booked slots between the start and end index. If _task_ is not
    # nil count only those slots that are assigned to this particular task.
    def getAllocatedSlots(startIdx, endIdx, task)
      # To speedup the counting we start with the first booked slot and end
      # with the last booked slot.
      startIdx = @firstBookedSlot if @firstBookedSlot &&
                                     startIdx < @firstBookedSlot
      endIdx = @lastBookedSlot + 1 if @lastBookedSlot &&
                                      endIdx > @lastBookedSlot + 1

      bookedSlots = 0
      startIdx.upto(endIdx - 1) do |idx|
        if (task.nil? && @scoreboard[idx].is_a?(Task)) ||
           (task && @scoreboard[idx] == task)
          bookedSlots += 1
        end
      end

      bookedSlots
    end

    # Count the free slots between the start and end index.
    def getFreeSlots(startIdx, endIdx)
      freeSlots = 0
      startIdx.upto(endIdx - 1) do |idx|
        freeSlots += 1 if @scoreboard[idx].nil?
      end

      freeSlots
    end

    # Returns true if the resource or any of its children is allocated during
    # the period specified with _startIdx_ and _endIdx_. If task is not nil
    # only allocations to this tasks are respected.
    def allocatedSub(startIdx, endIdx, task)
      if @property.container?
        @property.children.each do |resource|
          return true if resource.allocatedSub(@scenarioIdx, startIdx, endIdx,
                                               task)
        end
      else
        return false unless a('duties').include?(task)

        startIdx.upto(endIdx - 1) do |idx|
          return true if @scoreboard[idx] == task
        end
      end
      false
    end

    # Return the daily cost of a resource or resource group.
    def rate
      if @property.container?
        dailyRate = 0.0
        @property.children.each do |resource|
          dailyRate += resource.rate(@scenarioIdx)
        end
        dailyRate
      else
        a('rate')
      end
    end

  end

end

